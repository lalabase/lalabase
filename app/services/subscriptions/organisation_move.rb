# frozen_string_literal: true

# Moves ONE organisation from one billing account to another (K5 of
# doc/konto_ebene_plan.md). The operator path for the agency case: several
# organisations, one invoice.
#
# WHY THIS IS NOT A CONSOLE `update!`. Changing organisations.account_id touches
# no membership, so no callback fires and the seat event stream records NOTHING
# (verified: neither Organisation nor AccountAutoAssignable writes an event).
# The timeline would then break exactly where the account structure changes, and
# every period calculation across that seam would be wrong. This writes the two
# halves of the transition itself: a MOVED_OUT on the old account and a MOVED_IN
# on the new one for every currently counted membership, both with the SAME
# timestamp, so no reconstruction can see a gap or an overlap between them.
#
# WHAT DOES NOT MOVE (K6), AND WHAT DOES ANYWAY. Rows that already exist keep
# their account_id: ai_usage_rollups, seat_events, discounts, founder signups.
# The old account was the billing party when that usage happened.
#
# ⚠️ That holds for AGGREGATED consumption only, and the first wording of this
# class claimed more than that. An AiUsageRollup row is written when
# AiUsageRollupJob rolls up a CLOSED month, and Subscriptions::AiUsageAggregator
# reads organisation.account_id at THAT moment. Everything not yet rolled up --
# always the current month, plus any month whose run was missed -- is therefore
# booked in full to the NEW account, including the days before the move.
#
# Flushing those periods here would be worse, not better: ai_usage_rollups has
# ONE row per organisation and month (unique index), and the insert path skips
# conflicts silently. A partial row written now would make the monthly run's
# insert for the same month a no-op, and the rest of that month would be lost
# instead of merely misattributed. Splitting a month across two accounts needs a
# data-model change (doc/konto_ebene_plan.md K6, offen).
#
# So the task MEASURES the seam instead of hiding it: it names the last rolled-up
# period and says plainly what will land on the new account.
#
# A MOVE IS A PRICE CHANGE. Seats dedupe within an account (D4.1), so bundling
# usually LOWERS the total. Both accounts are measured before and after, and the
# task prints all four figures, because a silent price change is the thing an
# operator must not be able to cause by accident.
#
# AND IT CAN CROSS THE GUEST CEILING. `guest_max_organisations` defaults to 1 and
# counts the organisations OF ONE ACCOUNT in which a user is exclusively a guest
# (Subscriptions::GuestCeiling). Bundling is exactly what makes that number rise,
# so the move creates violations that did not exist while the same two
# organisations sat in two accounts. That is not cosmetic: it reaches the CUSTOMER
# through the non-blocking hint in Organisations::BaseController
# #warn_if_guest_ceiling_exceeded, on the org-admin's next membership write. So it
# is measured on both accounts, before and after, and the task names it wherever
# the number ROSE. The operator's answer is to raise the limit on the receiving
# account.
#
# WHAT THIS DOES NOT PROTECT AGAINST. The counted memberships are read before the
# assignment is committed, and nothing locks the organisation -- nothing could,
# since a concurrent membership write does not lock it either. A membership
# activated inside that window commits its own `activated` against the OLD account
# (its transaction still reads the old account_id) and gets no `moved_out`, so the
# old account keeps counting that seat; a deactivation in the same window leaves
# the new account counting one that is gone. Both are caught the next morning by
# SeatStreamDriftCheckJob, which is why this is named rather than built around:
# the window is narrow, the task is a rare operator call, and the alternative is
# a lock that only one of the two writers would take.
module Subscriptions
  class OrganisationMove
    # Refusals, all of them recoverable by the operator. Kept as symbols rather
    # than raised errors: the rake task has to print an explanation per case, and
    # a rescue chain would spread that vocabulary over two files.
    REFUSAL_SAME_ACCOUNT = :same_account
    REFUSAL_BILLING_STARTED = :billing_started

    Result = Struct.new(
      :organisation, :source_account, :target_account,
      :source_before, :source_after, :target_before, :target_after,
      :memberships_moved, :events_written, :source_emptied, :usage_rolled_up_through,
      :dry_run, :refused, keyword_init: true
    ) do
      def refused?
        refused.present?
      end

      def moved?
        !refused? && !dry_run
      end
    end

    # One figure pair per account, so "before" and "after" are the same shape and
    # the task can print them from one formatter.
    #
    # guest_violations belongs here and not next to the other consequences,
    # because it is the only one of them that is a MEASUREMENT of an account
    # rather than a statement about the move. Measuring it for both accounts
    # costs one query pair per organisation and buys the same rule on both
    # sides: report it where it ROSE, whichever account that is.
    Snapshot = Struct.new(:seats, :amount, :organisation_names,
                          :guest_violations, :guest_organisation_limit, keyword_init: true)

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # force: overrides the billing_starts_on refusal. Deliberately not a silent
    # default. For a MONTHLY account the arithmetic across a move IS defined (the
    # section split in doc/abrechnungsmodell_plan.md A3 covers it), but under R1
    # the invoice is written by hand, so an unnoticed move quietly produces a
    # wrong one.
    #
    # For a YEARLY source account it is NOT defined, and that is the heavier of
    # the two reasons (§10.1, decided 2026-08-06). Such an account keeps paying
    # its committed tier for the rest of the year (A4) while the receiving
    # account pays its section (A3), so the same people are billed twice until
    # the term ends. Forcing there is a contract decision, not an operator
    # shortcut -- billing_move_org.rake says so in its own words.
    #
    # The moment is taken ONCE here and shared by both halves of every
    # transition. Reading Time.current per row would let a reconstruction see a
    # seat as absent, or present, in the sliver between them.
    #
    # NOT a parameter, deliberately. A caller-supplied moment BEFORE the pair's
    # newest event would sort the moved_out ahead of the existing activated, so
    # the old account would keep counting the seat forever -- silently, and in
    # the direction that overcharges. There is no caller that needs to choose the
    # moment, so the safest surface is none.
    def initialize(organisation:, account:, dry_run: false, force: false)
      @organisation = organisation
      @target = account
      @dry_run = dry_run
      @force = force
      @at = Time.current
    end

    def call
      return refusal(REFUSAL_SAME_ACCOUNT) if @organisation.account_id == @target.id
      return refusal(REFUSAL_BILLING_STARTED) if billing_started? && !@force

      # Everything in ONE transaction, including the dry run: rolling back at the
      # end is what lets a preview report the REAL "after" figures instead of an
      # arithmetic guess at them. A guess is exactly what an operator would want
      # to double-check, which defeats the preview.
      #
      # requires_new: true is load-bearing and NOT decoration. Without it a
      # nested call joins the outer transaction, no savepoint exists, and the
      # ActiveRecord::Rollback below is swallowed -- the "preview" would write.
      # Measured 2026-08-06 from inside an ordinary transaction: assignment and
      # both seat events persisted. The specs cannot see this, because
      # use_transactional_fixtures opens its transaction with joinable: false,
      # which turns the inner block into a savepoint anyway.
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        result = perform
        raise ActiveRecord::Rollback if @dry_run
      end
      result
    end

    private

    def perform
      source = @organisation.account
      source_before = snapshot(source)
      target_before = snapshot(@target)

      memberships = counted_memberships
      written = write_transitions(source, memberships)
      @organisation.update!(account: @target)

      # Reloaded, not recomputed: the "after" figures have to come from the same
      # readers the customer page uses, or the preview and the page could disagree.
      #
      # BOTH reloads are their own statement, and that is not style. #snapshot
      # walks account.organisations, which LOADS and caches the association, so
      # the "before" snapshot leaves a collection behind that predates the move.
      # While the reload sat inside the Result argument list, the correctness of
      # target_after rested on it being written ABOVE that line -- keyword
      # arguments evaluate in source order, so a purely cosmetic regrouping of
      # the fields made the receiving account report its OLD seat count, i.e. an
      # amount that is too low. Measured: the reorder turns "Zugaenge: 0 -> 1"
      # into "0 -> 0" while the org list next to it is already correct.
      source_reloaded = source&.reload
      target_reloaded = @target.reload
      Result.new(
        organisation: @organisation, source_account: source, target_account: target_reloaded,
        source_before: source_before, source_after: snapshot(source_reloaded),
        target_before: target_before, target_after: snapshot(target_reloaded),
        memberships_moved: memberships.size, events_written: written,
        source_emptied: source_reloaded&.organisations&.empty? || false,
        usage_rolled_up_through: usage_rolled_up_through,
        dry_run: @dry_run, refused: nil
      )
    end

    # Exactly what SeatCounter counts for this organisation: an active membership
    # on a billable role. Written as the same join rather than reusing SeatCounter
    # because that one returns a COUNT for a whole account, and the transitions
    # need the individual user and role behind each seat.
    #
    # ActsAsTenant.with_tenant is mandatory: Role is tenant-scoped, and a rake
    # task runs without a tenant, so the join would return nothing at all.
    def counted_memberships
      ActsAsTenant.with_tenant(@organisation) do
        @organisation.memberships.joins(:role)
                     .where(active: true, roles: { billable: true })
                     .pluck(:user_id, :role_id)
      end
    end

    # Both halves, same timestamp. MOVED_OUT carries counted: false and MOVED_IN
    # counted: true, which is what SEAT_EVENT_COUNTED_EXPECTATION enforces on the
    # model -- a reconstruction reads `counted` and never interprets the type.
    #
    # The organisation without an account (account_id is nullable, E9b) gets only
    # the arriving half. There is no account to leave, and inventing one would put
    # a row on a billing party that never billed this organisation.
    def write_transitions(source, memberships)
      memberships.sum do |user_id, role_id|
        out = source && write_event(source, user_id, role_id,
                                    Constants::SEAT_EVENT_MOVED_OUT, counted: false)
        into = write_event(@target, user_id, role_id,
                           Constants::SEAT_EVENT_MOVED_IN, counted: true)
        [out, into].compact.size
      end
    end

    def write_event(account, user_id, role_id, event, counted:)
      SeatEvent.write_event(
        account: account, organisation_id: @organisation.id,
        organisation_name: @organisation.name, user_id: user_id, role_id: role_id,
        event: event, counted: counted, billable: true, occurred_at: @at,
        source: 'billing:move_org'
      )
    end

    # nil account (a source that never existed, or one measured after it lost its
    # last organisation) yields a snapshot of nothing rather than a zero: zero is
    # a measurement, and there was nothing to measure.
    def snapshot(account)
      return nil if account.nil?

      seats = SeatCounter.new(account).call
      Snapshot.new(
        seats: seats,
        amount: AmountPreview.call(account: account, seats: seats,
                                   billing_interval: account.billing_interval),
        organisation_names: account.organisations.order(:name).pluck(:name),
        guest_violations: GuestCeiling.new(account).violations.size,
        guest_organisation_limit: account.guest_max_organisations
      )
    end

    # The last month whose consumption is already booked, or nil when none is.
    # Everything AFTER it lands on the new account when the monthly job next
    # runs, including the days before this move -- see the header for why that
    # cannot be fixed here.
    #
    # A MAX over the existing rows, deliberately not a month calculation: the
    # definition of a month boundary lives in AiUsageAggregator and must not get
    # a second, subtly different copy here (CLAUDE.md, and the reason
    # #missing_periods is shaped the way it is).
    def usage_rolled_up_through
      ::AiUsageRollup.where(organisation_id: @organisation.id).maximum(:period_start)
    end

    # Asks Account, rather than repeating `billing_starts_on.present?`. The rule
    # that a NULL start date means "not clarified" (E4) lives in
    # Account#billing_start_decided?, and AmountPreview already reads it there;
    # a second hand-written copy is how the two answers start to differ.
    #
    # This ONE condition also carries §10.1: a yearly account that is actually
    # paying has a start date, so the A3-against-A4 double-payment can only be
    # reached by forcing. No second check for the interval -- it would be a
    # narrower copy of this one, true in strictly fewer cases and free to drift.
    def billing_started?
      @organisation.account&.billing_start_decided? || @target.billing_start_decided?
    end

    def refusal(reason)
      Result.new(organisation: @organisation, source_account: @organisation.account,
                 target_account: @target, dry_run: @dry_run, refused: reason,
                 memberships_moved: 0, events_written: 0, source_emptied: false,
                 usage_rolled_up_through: nil)
    end
  end
end
