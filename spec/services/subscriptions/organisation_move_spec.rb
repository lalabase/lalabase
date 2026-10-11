# frozen_string_literal: true

require 'rails_helper'

# What: moving one organisation between billing accounts (K5 of
#       doc/konto_ebene_plan.md).
# Type: service spec.
# Why:  Three properties here fail silently and cost money.
#
#   1. The move writes organisations.account_id and touches NO membership, so no
#      callback fires. Without the transitions written here the seat stream has a
#      hole exactly where the account structure changed, and every period
#      calculation across that seam is wrong. Nothing looks broken: both accounts
#      still reconstruct to plausible numbers, just not to the right ones.
#   2. A move IS a price change (seats dedupe within an account, D4.1). One that
#      happens without being shown is an invoice the operator did not intend.
#   3. K6: the usage history must NOT follow. Dragging it along would retroactively
#      change who was billed for what, which is the one thing an assignment must
#      never do.
RSpec.describe Subscriptions::OrganisationMove do
  let(:source) { create(:account, name: 'Altes Konto') }
  let(:target) { create(:account, name: 'Neues Konto') }
  let(:organisation) { create(:organisation, account: source) }

  def add_counted_member(org, user: create(:user))
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org, billable: true))
    end
    user
  end

  # The events this service is responsible for. Membership creation writes its own
  # `activated` rows, so "nothing was written" can only be asked about these.
  def operator_events
    SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENTS_FROM_OPERATOR)
  end

  def add_guest(org, user: create(:user))
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org, billable: false))
    end
    user
  end

  def move(**overrides)
    ActsAsTenant.without_tenant do
      described_class.call(organisation: organisation, account: target, **overrides)
    end
  end

  describe 'the move itself' do
    it 'reassigns the organisation to the target account' do
      add_counted_member(organisation)

      result = move

      expect(organisation.reload.account).to eq(target)
      expect(result).to be_moved
    end

    # [CRITICAL] The reason this is a task and not a console update!. Membership
    # callbacks structurally cannot see this transition, so the stream would
    # otherwise jump from "counted at the old account" to "counted at the new one"
    # with nothing in between.
    it 'writes a leaving and an arriving event per counted membership' do
      user = add_counted_member(organisation)

      move

      # Loaded once each; the N+1 detector counts repeated .first calls in a spec
      # as loudly as it counts them in production code.
      out = SeatEvent.where(account: source, event: Subscriptions::Constants::SEAT_EVENT_MOVED_OUT).to_a
      into = SeatEvent.where(account: target, event: Subscriptions::Constants::SEAT_EVENT_MOVED_IN).to_a
      expect(out.map(&:user_id)).to contain_exactly(user.id)
      expect(into.map(&:user_id)).to contain_exactly(user.id)
      # Same moment for both halves: a reconstruction between two different
      # timestamps would see the seat either twice or not at all.
      expect(out.first.occurred_at).to eq(into.first.occurred_at)
      # `counted` is what a reconstruction reads; the types are never interpreted.
      expect(out.first.counted).to be(false)
      expect(into.first.counted).to be(true)
      # `billable` is written as a literal true in the service. Nothing validates
      # it against the role -- SEAT_EVENT_COUNTED_EXPECTATION pairs `event` with
      # `counted` and says nothing about billable -- so a row claiming
      # "counted, but not billable" would be accepted and would contradict the
      # very query that selected this membership.
      expect(out.first.billable).to be(true)
      expect(into.first.billable).to be(true)
    end

    it 'ignores memberships that are not counted' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: create(:user), organisation: organisation, active: false,
                            role: create(:role, organisation: organisation, billable: true))
        create(:membership, user: create(:user), organisation: organisation, active: true,
                            role: create(:role, organisation: organisation, billable: false))
      end

      result = move

      expect(result.memberships_moved).to eq(0)
      expect(operator_events).to be_empty
    end

    # [CRITICAL] The payoff of writing the transitions at all: after a move the
    # stream still agrees with what the counter says, for BOTH accounts. This is
    # the property an invoice depends on, and it is the one that a bare
    # update!(account:) would break while everything kept looking fine.
    # Asked through Subscriptions::SeatStreamDrift, the SAME reader the nightly
    # check uses, rather than by reconstructing here. A hand-rolled comparison in
    # a spec would be a second definition of "do these agree", and the one that
    # decides in production is that one.
    it 'leaves both accounts reconstructible and in agreement with SeatCounter' do
      SystemSetting.seat_stream_opened_at!(1.hour.ago)
      add_counted_member(organisation)
      add_counted_member(create(:organisation, account: target))

      move

      findings = Subscriptions::SeatStreamDrift.call
      expect(findings).to be_empty,
                          findings.map { |f| "#{f.account.name}: #{f.kind} #{f.live} vs #{f.from_stream}" }.join(', ')
    end

    # The other half of the same statement, and the one that makes the example
    # above mean something: without the transitions the stream and the counter
    # disagree. Written as a probe rather than trusted, because "no findings" is
    # also what an empty sweep returns.
    it 'is the transitions that keep them in agreement, not the sweep being blind' do
      SystemSetting.seat_stream_opened_at!(1.hour.ago)
      add_counted_member(organisation)

      # The move a console would do: account_id only, no events.
      ActsAsTenant.without_tenant { organisation.update!(account: target) }

      expect(Subscriptions::SeatStreamDrift.call.map(&:kind))
        .to include(Subscriptions::SeatStreamDrift::KIND_MISMATCH)
    end
  end

  # The promise of the account level, and the reason the whole slice exists. Until
  # a move happens, Subscriptions::SeatCounter's dedup has nothing to dedup:
  # AccountAutoAssignable gives every organisation its own account, so no account
  # in production has ever held two.
  describe 'the dedup this makes possible' do
    it 'counts a person working in two organisations of one account only once' do
      shared = create(:user)
      other_org = create(:organisation, account: target)
      add_counted_member(organisation, user: shared)
      add_counted_member(other_org, user: shared)
      add_counted_member(other_org)

      before_sum = Subscriptions::SeatCounter.new(source).call +
                   Subscriptions::SeatCounter.new(target).call
      move
      after = Subscriptions::SeatCounter.new(target.reload).call

      # Pinned as concrete numbers, not just "smaller": 1 + 2 separately, 2 once
      # bundled. A bare `be < before_sum` would also pass if the move lost a seat.
      expect(before_sum).to eq(3)
      expect(after).to eq(2)
    end
  end

  describe 'the price it shows' do
    it 'reports seats and amount for both accounts, before and after' do
      add_counted_member(organisation)
      add_counted_member(create(:organisation, account: target))

      result = move

      expect(result.source_before.seats).to eq(1)
      expect(result.source_after.seats).to eq(0)
      expect(result.target_before.seats).to eq(1)
      expect(result.target_after.seats).to eq(2)
      expect(result.target_after.organisation_names).to include(organisation.name)
    end
  end

  # The consequence with no K-number and the only one that reaches the CUSTOMER.
  # `guest_max_organisations` defaults to 1 and counts the organisations OF ONE
  # ACCOUNT in which a user is exclusively a guest, so bundling -- the entire
  # point of this slice -- is what makes that number cross the limit.
  describe 'the guest ceiling it can cross' do
    it 'reports the violations the bundling creates on the receiving account' do
      shared_guest = create(:user)
      other_org = create(:organisation, account: target)
      add_guest(organisation, user: shared_guest)
      add_guest(other_org, user: shared_guest)

      result = move

      # Pinned as concrete numbers in both directions. `be > before` would also
      # pass if the guest had been violating already, which is the one case this
      # line must NOT report: two accounts of one org each cannot exceed a limit
      # of one.
      expect(result.target_before.guest_violations).to eq(0)
      expect(result.target_after.guest_violations).to eq(1)
      expect(result.target_after.guest_organisation_limit).to eq(1)
    end

    it 'reports none when the moved people are billable rather than guests' do
      add_counted_member(organisation)
      add_counted_member(create(:organisation, account: target))

      result = move

      # A billable member is a paid seat and never a guest, no matter how many
      # organisations they work in (GuestCeiling, Fund 1).
      expect(result.target_after.guest_violations).to eq(0)
    end

    it 'stays clear when the guest works in only one of the bundled organisations' do
      add_guest(organisation)
      add_guest(create(:organisation, account: target))

      expect(move.target_after.guest_violations).to eq(0)
    end
  end

  describe 'DRY_RUN' do
    # [CRITICAL] A preview that wrote anything would be worse than no preview.
    it 'writes neither the assignment nor a single event' do
      add_counted_member(organisation)

      result = move(dry_run: true)

      expect(organisation.reload.account).to eq(source)
      # Scoped to the operator types: the membership above already produced an
      # `activated` row, so the table is never empty and a bare count would be
      # asserting something else.
      expect(operator_events).to be_empty
      expect(result).not_to be_moved
    end

    # [CRITICAL] The savepoint. Without requires_new: true the inner transaction
    # JOINS an outer one, no savepoint exists, and ActiveRecord::Rollback is
    # swallowed -- the preview writes. Measured before the fix: assignment and
    # both events persisted.
    #
    # The outer transaction here is an ordinary (joinable) one, which is what
    # makes this example able to tell the difference. The transactional-fixture
    # transaction around every example cannot: Rails opens it with
    # joinable: false, so the inner block becomes a savepoint either way.
    it 'still writes nothing when the caller already opened a transaction' do
      add_counted_member(organisation)

      ActiveRecord::Base.transaction do
        move(dry_run: true)

        expect(organisation.reload.account).to eq(source)
        expect(operator_events).to be_empty
      end

      expect(organisation.reload.account).to eq(source)
      expect(operator_events).to be_empty
    end

    # And it still has to be USEFUL: the figures come from a real move that was
    # rolled back, not from arithmetic on the side, so the preview cannot disagree
    # with what the real run will do.
    it 'still reports the figures the real move would produce' do
      add_counted_member(organisation)
      add_counted_member(create(:organisation, account: target))

      result = move(dry_run: true)

      expect(result.target_after.seats).to eq(2)
      expect(result.source_after.seats).to eq(0)
    end
  end

  describe 'refusals' do
    # K5. The arithmetic across a move is defined, but under R1 the invoice is
    # written by hand, so an unnoticed move silently produces a wrong one.
    it 'refuses when the receiving account is already being billed' do
      target.update!(billing_starts_on: Date.current)
      add_counted_member(organisation)

      result = move

      expect(result.refused).to eq(described_class::REFUSAL_BILLING_STARTED)
      expect(organisation.reload.account).to eq(source)
      expect(operator_events).to be_empty
    end

    it 'refuses when the giving account is already being billed' do
      source.update!(billing_starts_on: Date.current)

      expect(move.refused).to eq(described_class::REFUSAL_BILLING_STARTED)
      expect(organisation.reload.account).to eq(source)
    end

    it 'goes ahead when the operator overrides deliberately' do
      target.update!(billing_starts_on: Date.current)
      add_counted_member(organisation)

      result = move(force: true)

      expect(result).to be_moved
      expect(organisation.reload.account).to eq(target)
    end

    it 'does nothing when the organisation is already in the target account' do
      organisation.update!(account: target)

      result = move

      expect(result.refused).to eq(described_class::REFUSAL_SAME_ACCOUNT)
      expect(operator_events).to be_empty
    end
  end

  # K6. The first version of this group asserted that rollups and discounts keep
  # their account_id -- and nothing in this service touches either, so those
  # expectations held under every possible mutation, including a no-op. They
  # documented a decision and tested nothing.
  #
  # What can actually break is one step further out: AiUsageAggregator reads
  # organisation.account_id at AGGREGATION time, so consumption that has no
  # rollup row yet follows the organisation. That is the real edge, it is
  # measured below rather than assumed, and the task prints it.
  describe 'what does not move, and what does anyway (K6)' do
    it 'leaves usage rollups and seat events on the old account' do
      user = add_counted_member(organisation)
      rollup = create(:ai_usage_rollup, account: source, organisation: organisation)
      earlier = SeatEvent.where(account: source, user_id: user.id).to_a

      move

      expect(rollup.reload.account_id).to eq(source.id)
      expect(earlier.map { |event| event.reload.account_id }).to all(eq(source.id))
    end

    it 'leaves discounts with the account rather than the organisation' do
      discount = create(:account_discount, account: source)

      move

      expect(discount.reload.account_id).to eq(source.id)
    end

    # [CRITICAL] The seam the task has to tell the operator about. Consumption of
    # a period that was never rolled up is booked to whatever account the
    # organisation belongs to WHEN the monthly job runs, so the whole month lands
    # on the new account, including the days before the move.
    #
    # Not fixable by flushing here: ai_usage_rollups holds one row per
    # organisation and month (unique index) and the insert skips conflicts
    # silently, so a partial row written now would make the monthly run's insert
    # a no-op and LOSE the rest of the month. Splitting a month across accounts
    # needs a data-model change.
    it 'books a not-yet-aggregated period to the NEW account, whole' do
      period = 1.month.ago.beginning_of_month.to_date
      create(:ai_usage, organisation: organisation, used_at: period + 2.days)

      move
      Subscriptions::AiUsageAggregator.call(period_start: period)

      rollup = AiUsageRollup.find_by(organisation_id: organisation.id, period_start: period)
      expect(rollup.account_id).to eq(target.id)
    end

    # What the operator is told, so the sentence in the task cannot drift away
    # from the data it describes.
    it 'reports the last period whose consumption is already booked' do
      period = 2.months.ago.beginning_of_month.to_date
      create(:ai_usage_rollup, account: source, organisation: organisation, period_start: period)

      expect(move.usage_rolled_up_through).to eq(period)
    end

    it 'reports nothing rolled up when the organisation has no rollup at all' do
      expect(move.usage_rolled_up_through).to be_nil
    end
  end

  # K7. Deleting would take discounts and a founder application with it through
  # dependent: :destroy, and those are records of what was agreed.
  describe 'the emptied account (K7)' do
    it 'survives losing its last organisation, and the result says so' do
      add_counted_member(organisation)

      result = move

      expect(Account.exists?(source.id)).to be(true)
      expect(result.source_emptied).to be(true)
    end

    it 'does not claim emptiness when the account keeps another organisation' do
      create(:organisation, account: source)

      expect(move.source_emptied).to be(false)
    end
  end

  # E9b: organisations.account_id is nullable. There is no account to leave, so
  # only the arriving half is written -- inventing a leaving event would put a row
  # on a billing party that never billed this organisation.
  describe 'an organisation without any account' do
    it 'moves in without writing a leaving event' do
      organisation.update_columns(account_id: nil)
      user = add_counted_member(organisation)

      result = move

      expect(organisation.reload.account).to eq(target)
      expect(result.source_before).to be_nil
      expect(SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENT_MOVED_OUT)).to be_empty
      expect(SeatEvent.where(account: target, event: Subscriptions::Constants::SEAT_EVENT_MOVED_IN)
                      .pluck(:user_id)).to contain_exactly(user.id)
    end
  end
end
