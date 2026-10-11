# frozen_string_literal: true

require 'rails_helper'

# The read side and the append-only guarantee. `up_to` and `counting` are what
# T18 (snapshot job) will build on, so they are pinned before the first consumer
# exists rather than after.
RSpec.describe SeatEvent do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }
  let(:user) { create(:user) }

  def build_event(attrs = {})
    described_class.new(
      {
        account: account,
        organisation_id: organisation.id,
        organisation_name: organisation.name,
        user_id: user.id,
        event: Subscriptions::Constants::SEAT_EVENT_ACTIVATED,
        occurred_at: Time.current,
        billable: true,
        counted: true
      }.merge(attrs)
    )
  end

  describe 'validations' do
    it 'accepts a complete row' do
      expect(build_event).to be_valid
    end

    it 'rejects an unknown event type' do
      expect(build_event(event: 'suspended')).not_to be_valid
    end

    it 'accepts every declared event type with its expected counted value' do
      Subscriptions::Constants::SEAT_EVENTS.each do |type|
        counted = Subscriptions::Constants::SEAT_EVENT_COUNTED_EXPECTATION.fetch(type, false)
        expect(build_event(event: type, counted: counted)).to be_valid, "#{type} was rejected"
      end
    end

    # The table itself, as literals. The examples below DERIVE from it, so they
    # cover every entry but can never notice a MISSING one: drop `deactivated`
    # and they simply stop testing it and stay green. Measured, not assumed --
    # that mutation left 23 examples passing. This is the assertion that bites.
    it 'expects a counted value for every type except opening' do
      expect(Subscriptions::Constants::SEAT_EVENT_COUNTED_EXPECTATION).to eq(
        'activated' => true,
        'moved_in' => true,
        'deactivated' => false,
        'removed' => false,
        'moved_out' => false
      )
    end

    # Type and `counted` have to agree, in BOTH directions. The dangerous half is
    # a stopping type that claims a seat: it over-counts every later
    # reconstruction, so the invoice is too high. The other half under-counts.
    # Derived from the table, so a seventh type is covered the day it is added.
    Subscriptions::Constants::SEAT_EVENT_COUNTED_EXPECTATION.each do |type, expected|
      it "rejects #{type} with counted: #{!expected}" do
        event = build_event(event: type, counted: !expected)

        expect(event).not_to be_valid
        expect(event.errors[:counted]).to be_present
      end

      it "accepts #{type} with counted: #{expected}" do
        expect(build_event(event: type, counted: expected)).to be_valid
      end
    end

    # `opening` is the one type without an expectation: it records the state that
    # WAS, and that may be either. Without this the table could be widened to
    # cover it and nothing would fail.
    it 'lets opening carry either value' do
      opening = Subscriptions::Constants::SEAT_EVENT_OPENING

      expect(build_event(event: opening, counted: true)).to be_valid
      expect(build_event(event: opening, counted: false)).to be_valid
    end

    it 'renders both disagreement messages in both locales' do
      stopping = build_event(event: Subscriptions::Constants::SEAT_EVENT_MOVED_OUT, counted: true)
      starting = build_event(event: Subscriptions::Constants::SEAT_EVENT_MOVED_IN, counted: false)
      [stopping, starting].each(&:valid?)

      expect(stopping.errors.full_messages.join).to include('zählt danach nicht mehr')
      expect(starting.errors.full_messages.join).to include('zählt ab dann')

      I18n.with_locale(:en) do
        en_stopping = build_event(event: Subscriptions::Constants::SEAT_EVENT_MOVED_OUT, counted: true)
        en_starting = build_event(event: Subscriptions::Constants::SEAT_EVENT_MOVED_IN, counted: false)
        [en_stopping, en_starting].each(&:valid?)

        expect(en_stopping.errors.full_messages.join).to include('stops counting')
        expect(en_starting.errors.full_messages.join).to include('starts counting')
      end
    end

    it 'rejects a row without the organisation name snapshot' do
      # Without it a post-deletion row is an unlabelled UUID on an invoice.
      expect(build_event(organisation_name: nil)).not_to be_valid
    end

    it 'rejects nil for the two booleans rather than treating it as false' do
      expect(build_event(counted: nil)).not_to be_valid
      expect(build_event(billable: nil)).not_to be_valid
    end
  end

  describe 'append-only' do
    let(:event) { build_event.tap(&:save!) }

    it 'refuses an update' do
      # A field the type/counted rule does not touch, so this still fails on
      # readonly? and not on a validation -- otherwise the append-only guarantee
      # would be proven by the wrong error.
      expect { event.update!(organisation_name: 'Umbenannt') }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it 'refuses a destroy' do
      expect(event.destroy).to be(false)
      expect(described_class.exists?(event.id)).to be(true)
    end
  end

  describe 'scopes' do
    let!(:older) { build_event(occurred_at: 3.days.ago, counted: true).tap(&:save!) }
    let!(:newer) do
      build_event(occurred_at: 1.day.ago, counted: false,
                  event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED).tap(&:save!)
    end

    it 'orders chronologically' do
      expect(described_class.chronological.to_a).to eq([older, newer])
    end

    describe '.up_to' do
      it 'includes an event exactly on the boundary and excludes the one after it' do
        # n-1 / n / n+1 around the cut-off: an exclusive end would drop the very
        # event that defines the state on that date.
        expect(described_class.up_to(older.occurred_at)).to contain_exactly(older)
        expect(described_class.up_to(newer.occurred_at)).to contain_exactly(older, newer)
        expect(described_class.up_to(4.days.ago)).to be_empty
      end
    end

    describe '.counting' do
      it 'keeps only the seat-bearing rows' do
        expect(described_class.counting).to contain_exactly(older)
      end
    end
  end

  describe '#organisation_deleted?' do
    it 'is false while the organisation is still there' do
      expect(build_event.tap(&:save!).organisation_deleted?).to be(false)
    end
  end

  # The reason .for_account exists, demonstrated rather than asserted. After a
  # move the SAME (organisation, user) pair carries a moved_out in the old and a
  # moved_in in the new account, both with the SAME occurred_at. "The newest
  # event for this pair" therefore has no answer until one account is picked,
  # and without the filter the tie-break falls to created_at, i.e. insert order.
  describe '.for_account after an organisation moved' do
    let(:new_account) { create(:account) }
    let(:moment) { Time.current }

    before do
      # Insert the ARRIVING half first, so a reconstruction that ignores the
      # account and falls back on created_at would pick the wrong one and report
      # the seat as still counted in the old account.
      build_event(account: new_account, event: Subscriptions::Constants::SEAT_EVENT_MOVED_IN,
                  counted: true, occurred_at: moment).save!
      build_event(account: account, event: Subscriptions::Constants::SEAT_EVENT_MOVED_OUT,
                  counted: false, occurred_at: moment).save!
    end

    # Against the SHIPPED reconstruction, not a spec helper: otherwise the example
    # would only prove that the helper needs the filter.
    it 'reports the seat in the new account and not in the old one' do
      expect(described_class.counted_user_ids_for(account: new_account)).to eq([user.id])
      expect(described_class.counted_user_ids_for(account: account)).to be_empty
    end
  end

  # The marker, not the rows, is what says from when the stream is complete. An
  # `opening` row is bound to a PAIR; the question is about the SYSTEM, and the
  # earlier derived version could not answer it for an installation whose
  # recorder ran from day one (no rows written, so nothing to derive from).
  describe '.reconstructible_from' do
    let(:other_account) { create(:account) }

    it 'is nil while the backfill has never run' do
      build_event(event: Subscriptions::Constants::SEAT_EVENT_ACTIVATED).save!

      expect(described_class.reconstructible_from(account)).to be_nil
    end

    it 'is the marker for an account that predates it' do
      opened_at = 2.days.ago.change(usec: 0)
      SystemSetting.seat_stream_opened_at!(opened_at)
      # Backdated on purpose: the factory creates the account inside this example,
      # so without it the account would be YOUNGER and the max would (correctly)
      # pick its creation instead.
      account.update_column(:created_at, 3.days.ago)

      expect(described_class.reconstructible_from(account)).to be_within(1.second).of(opened_at)
    end

    # [CRITICAL] The case no pair-bound row could ever cover: this account
    # contributed nothing to the backfill, because it had nobody to open. On an
    # installation whose recorder ran from day one, NO account contributes.
    it 'covers an account that contributed no opening row' do
      opened_at = 2.days.ago.change(usec: 0)
      SystemSetting.seat_stream_opened_at!(opened_at)
      other_account.update_column(:created_at, 3.days.ago)

      expect(described_class.reconstructible_from(other_account))
        .to be_within(1.second).of(opened_at)
      expect(described_class.where(event: Subscriptions::Constants::SEAT_EVENT_OPENING)).to be_empty
    end

    # [CRITICAL] An account born after the run is readable from the MARKER, not
    # from its own creation. Before it existed it held zero seats, and zero is a
    # measurement here rather than the lie §3 forbids. It needs no opening of its
    # own: it started empty, and every membership since produced its own event.
    #
    # The earlier version answered the account's creation moment, which left the
    # signup month of every new customer -- the month of their FIRST invoice --
    # without a seat peak (review finding on #529, measured).
    it 'is the marker for an account younger than it, not the account birthday' do
      opened_at = 2.days.ago.change(usec: 0)
      SystemSetting.seat_stream_opened_at!(opened_at)
      newborn = create(:account)

      expect(newborn.created_at).to be > opened_at
      expect(described_class.reconstructible_from(newborn)).to be_within(1.second).of(opened_at)
    end

    # Write-once: a second run must not move the moment forward, which would
    # declare earlier, correctly reconstructible periods unreadable.
    it 'keeps the first moment when the backfill runs again' do
      first = 3.days.ago.change(usec: 0)
      SystemSetting.seat_stream_opened_at!(first)
      SystemSetting.seat_stream_opened_at!(Time.current)

      expect(SystemSetting.seat_stream_opened_at).to be_within(1.second).of(first)
    end
  end

  # The two families drive who may write what: SeatEventRecording produces the
  # membership half from callbacks, the operator tasks produce the other. A type
  # in both would make that distinction meaningless without failing anywhere.
  describe 'event families' do
    it 'are disjoint and together make up the accepted set' do
      membership = Subscriptions::Constants::SEAT_EVENTS_FROM_MEMBERSHIP
      operator = Subscriptions::Constants::SEAT_EVENTS_FROM_OPERATOR

      expect(membership & operator).to be_empty
      # Literals, not (membership + operator): SEAT_EVENTS IS that sum, so the
      # comparison would be the definition against itself and would stay green if
      # someone dropped a type from one of the families.
      expect(Subscriptions::Constants::SEAT_EVENTS)
        .to match_array(%w[activated deactivated removed opening moved_in moved_out])
    end
  end
end
