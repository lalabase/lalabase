# frozen_string_literal: true

# Writes the one-time starting state of the seat event stream (M0b,
# doc/abrechnungsmodell_plan.md §3).
#
# WHY THIS EXISTS. SeatEventRecording records TRANSITIONS, and it started on a
# running system. It therefore knows only who has changed since the deploy;
# everybody who was simply already there is invisible. Measured on production
# 2026-08-06: SeatCounter said 3 for an account, a reconstruction from the
# stream said 0. Without an explicit opening, every quiet account reconstructs
# to zero seats, which is not a slow answer but a wrong one, and it is wrong
# for exactly the calm long-standing customers.
#
# WHAT IT WRITES. One `opening` row per currently COUNTED membership that has
# no seat event at all. Two deliberate restrictions:
#
#   * Only counted memberships. An uncounted one contributes nothing to a
#     reconstruction, and a row asserting "was not counted" would be noise.
#   * Only pairs with NO history. A pair that already carries an `activated`
#     is reconstructible on its own; adding an opening would restate it with a
#     later timestamp and gain nothing. This is also what makes the run
#     idempotent: after it, those pairs have an event, so a second run finds
#     none.
#
# THE TIMESTAMP IS THE RUN, not a made-up date in the past. The stream must not
# claim to have known something it did not know. Periods before it are simply
# not reconstructible, and SeatEvent.reconstructible_from says so rather than
# answering zero.
module Subscriptions
  class SeatOpeningBackfill
    Result = Struct.new(:written, :accounts_touched, :pairs_seen, :at, keyword_init: true)

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # at: one moment for the WHOLE run, not per row. Every opening of one run
    # shares a timestamp, so "the state when the stream began" is a single point
    # rather than a smear across however long the run took.
    def initialize(dry_run: false, at: Time.current)
      @dry_run = dry_run
      @at = at
      @written = 0
      @accounts_touched = 0
      @pairs_seen = 0
    end

    def call
      ::Account.includes(:organisations).find_each { |account| backfill_account(account) }

      # The marker, not the rows, is what makes the stream reconstructible. It is
      # set even when NOTHING was written: on an installation whose recorder ran
      # from day one every pair already has history, the run correctly writes
      # zero rows, and without the marker that installation could never be
      # reconstructed at all. Write-once, so a second run cannot move the moment.
      SystemSetting.seat_stream_opened_at!(@at) unless @dry_run

      Result.new(written: @written, accounts_touched: @accounts_touched,
                 pairs_seen: @pairs_seen, at: @at)
    end

    private

    # create! per row rather than insert_all!, deliberately: this table just grew
    # an invariant (type and `counted` must agree), and the run that lays the
    # FOUNDATION of every later billing figure is the last place to write past
    # the validations. One transaction per account, so a rejected row aborts that
    # account instead of leaving half an opening state behind. The volume makes
    # the trade free: production holds 16 memberships in total.
    def backfill_account(account)
      known = known_seat_pairs_for_account(account)
      rows = account.organisations.flat_map { |org| opening_rows_for_organisation(org, account, known) }
      return if rows.empty?

      @accounts_touched += 1
      @written += rows.size
      return if @dry_run

      SeatEvent.transaction { rows.each { |row| SeatEvent.create!(row) } }
    end

    # The pairs this account already has any history for, in ONE query rather
    # than one per membership. A pair belongs to exactly one organisation and an
    # organisation to exactly one account, so the account's own rows are the
    # complete answer.
    def known_seat_pairs_for_account(account)
      SeatEvent.for_account(account).pluck(:organisation_id, :user_id).to_set
    end

    # Per-organisation with_tenant is mandatory, not caution: Role is
    # acts_as_tenant(:organisation), so membership.role only resolves the
    # billable flag under that organisation's own tenant. Same reason as
    # Account#eligible_owners_by_organisation.
    def opening_rows_for_organisation(organisation, account, known)
      ActsAsTenant.with_tenant(organisation) do
        organisation.memberships.active.joins(:role).where(roles: { billable: true })
                    .pluck(:user_id, :role_id)
                    .filter_map do |user_id, role_id|
          @pairs_seen += 1
          next if known.include?([organisation.id, user_id])

          row_for(organisation, account, user_id, role_id)
        end
      end
    end

    def row_for(organisation, account, user_id, role_id)
      {
        # The loaded object, not account_id: belongs_to :account validates
        # presence, and an id would make that validation fetch the same account
        # again for every single row.
        account: account,
        organisation_id: organisation.id,
        # Snapshot, never organisation&.name at read time: the row has to stay
        # readable once the organisation is gone.
        organisation_name: organisation.name,
        user_id: user_id,
        role_id: role_id,
        event: Subscriptions::Constants::SEAT_EVENT_OPENING,
        billable: true,
        counted: true,
        occurred_at: @at
      }
    end
  end
end
