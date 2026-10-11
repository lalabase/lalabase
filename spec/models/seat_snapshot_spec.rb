# frozen_string_literal: true

require 'rails_helper'

# What: the consistency invariant of the month-boundary seat snapshot (M1a,
#       doc/abrechnungsmodell_plan.md §4 step 1) and the ONE boundary
#       conversion (A6).
# Type: model spec.
# Why:  seat_count is redundant by design -- the distinct users across pairs
#       (D4.1) -- and a row where the two disagree poisons the invoice or the
#       support answer silently. The validation is what turns "enforced at
#       write time" from a hope into a rule, so every branch of it is pinned
#       here with a row that MUST NOT be savable.
RSpec.describe SeatSnapshot do
  let(:account) { create(:account) }

  # Two organisations of ONE account, the same user in both: one seat, two
  # pairs. The shape every dedup assertion below builds on.
  let(:user_id) { SecureRandom.uuid }
  let(:pair_one) do
    { 'organisation_id' => SecureRandom.uuid, 'organisation_name' => 'Org Eins',
      'user_id' => user_id }
  end
  let(:pair_two) do
    { 'organisation_id' => SecureRandom.uuid, 'organisation_name' => 'Org Zwei',
      'user_id' => user_id }
  end

  def build_snapshot(attrs = {})
    described_class.new(
      {
        account: account,
        period_start: Date.new(2026, 7, 1),
        status: Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_OK,
        seat_count: 0,
        pairs: [],
        computed_at: Time.current
      }.merge(attrs)
    )
  end

  describe 'ok rows' do
    it 'accepts a measured empty account (0 is a measurement, not a gap)' do
      expect(build_snapshot).to be_valid
    end

    it 'accepts a count that equals the DISTINCT users across the pairs' do
      expect(build_snapshot(seat_count: 1, pairs: [pair_one, pair_two])).to be_valid
    end

    # The dedup rule inside the invariant: the same user in two organisations
    # of this account is ONE seat, so a count equal to the PAIR count is the
    # plus/minus figure and must not be savable.
    it 'rejects a count that counts pairs instead of users' do
      snapshot = build_snapshot(seat_count: 2, pairs: [pair_one, pair_two])

      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:seat_count]).to be_present
    end

    it 'rejects a missing count' do
      expect(build_snapshot(seat_count: nil, pairs: [pair_one])).not_to be_valid
    end

    it 'rejects an error text on a measured row' do
      expect(build_snapshot(error: 'kaputt')).not_to be_valid
    end

    # An entry without the name would become an unlabelled UUID the moment its
    # organisation is deleted -- and answering §5 after a deletion is the whole
    # reason the name is frozen in.
    it 'rejects a pair entry missing one of the three keys' do
      %w[organisation_id organisation_name user_id].each do |key|
        snapshot = build_snapshot(seat_count: 1, pairs: [pair_one.except(key)])

        expect(snapshot).not_to be_valid, "entry without #{key} was accepted"
        expect(snapshot.errors[:pairs]).to be_present
      end
    end

    # In-memory callers may build with symbols; a reloaded JSONB column always
    # answers with strings. The invariant must read both the same way.
    it 'reads symbol-keyed pairs like string-keyed ones' do
      expect(build_snapshot(seat_count: 1, pairs: [pair_one.symbolize_keys])).to be_valid
    end

    # raise_on_missing_translations is off in test, so a missing key would fall
    # back to "translation missing" silently -- errors[:seat_count].present?
    # alone cannot see that. Same guard shape as seat_event_spec.
    it 'renders the count mismatch message in both locales' do
      snapshot = build_snapshot(seat_count: 2, pairs: [pair_one, pair_two])
      snapshot.valid?

      expect(snapshot.errors.full_messages.join).to include('Zahl verschiedener User')

      I18n.with_locale(:en) do
        en_snapshot = build_snapshot(seat_count: 2, pairs: [pair_one, pair_two])
        en_snapshot.valid?

        expect(en_snapshot.errors.full_messages.join).to include('distinct users')
      end
    end
  end

  describe 'not_reconstructible rows' do
    let(:status) { Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE }

    it 'accepts NULL count, empty pairs, no error' do
      expect(build_snapshot(status: status, seat_count: nil)).to be_valid
    end

    # §3 verbatim: where there is no measurement, a zero would be a lie. This
    # is the row shape that must be UNWRITABLE, not merely discouraged.
    it 'rejects a zero where there is no measurement' do
      snapshot = build_snapshot(status: status, seat_count: 0)

      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:seat_count]).to be_present
    end

    it 'rejects pairs and error text' do
      expect(build_snapshot(status: status, seat_count: nil, pairs: [pair_one])).not_to be_valid
      expect(build_snapshot(status: status, seat_count: nil, error: 'kaputt')).not_to be_valid
    end
  end

  describe 'failed rows' do
    let(:status) { Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED }

    it 'accepts NULL count, empty pairs and the error text' do
      expect(build_snapshot(status: status, seat_count: nil, error: 'RuntimeError: kaputt')).to be_valid
    end

    # T18 point 3 wants the failure HELD, and a failed row without the error is
    # a held failure nobody can act on.
    it 'rejects a failed row without the error text' do
      expect(build_snapshot(status: status, seat_count: nil)).not_to be_valid
    end

    it 'rejects a count on a failed row' do
      expect(build_snapshot(status: status, seat_count: 0, error: 'kaputt')).not_to be_valid
    end
  end

  describe 'status and period_start' do
    it 'rejects an unknown status' do
      expect(build_snapshot(status: 'pending')).not_to be_valid
    end

    # A period_start off the first would start a second grid of boundaries next
    # to the real one; the unique index cannot see that collision.
    it 'rejects a period_start that is not the first of a month' do
      expect(build_snapshot(period_start: Date.new(2026, 7, 15))).not_to be_valid
    end
  end

  describe 'one row per account and boundary' do
    it 'refuses a second row for the same account and period at the database' do
      create(:seat_snapshot, account: account, period_start: Date.new(2026, 7, 1))

      expect { build_snapshot.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe '.boundary_moment' do
    # Hardcoded UTC instants, NOT derived from the method under test: an
    # expectation computed from the same helper would stay green with any zone.
    # Both offsets pinned, so the assertion is "Europe/Berlin" and not "UTC+2".
    it 'is midnight Europe/Berlin, i.e. 22:00 UTC the previous day in summer' do
      expect(described_class.boundary_moment(Date.new(2026, 9, 1)))
        .to eq(Time.utc(2026, 8, 31, 22, 0, 0))
    end

    it 'is 23:00 UTC the previous day in winter' do
      expect(described_class.boundary_moment(Date.new(2026, 1, 1)))
        .to eq(Time.utc(2025, 12, 31, 23, 0, 0))
    end
  end

  # The one parser for a month typed by a human. Both entry points that take one
  # (the admin page, the seat_peaks:* tasks) go through it, so the two traps
  # below are refused once instead of in each caller.
  describe '.parse_period' do
    it 'reads a plain ISO date and names the month it lies in' do
      expect(described_class.parse_period('2026-08-17')).to eq(Date.new(2026, 8, 1))
    end

    # Date.parse reads BOTH of these as 2026-08-01 and does not complain, so a
    # typo in a rake call would have produced a confident answer about a month
    # nobody asked for.
    ['Augustsonstwas', 'letzter Monat', 'August', '', nil].each do |input|
      it "refuses #{input.inspect}" do
        expect(described_class.parse_period(input)).to be_nil
      end
    end

    # [CRITICAL] A valid Ruby Date that PostgreSQL cannot store: year 10000 BC.
    # Date.iso8601 accepts it, and the next query dies with
    # PG::DatetimeFieldOverflow -- a 500 on the page whose contract is to answer
    # instead of crashing (review finding on #529).
    #
    # Here only the PARSER is asked. That the guard really sits in front of the
    # database is proven where the query happens: accounts_seat_peak_spec.rb and
    # seat_peaks_spec.rb, both "a year the database cannot store". The second
    # expectation below is not decoration either -- without it this example would
    # keep passing if Date.iso8601 ever started rejecting the input on its own,
    # and would then say nothing about the guard.
    it 'refuses a negative year that the database cannot store' do
      expect(described_class.parse_period('-9999-01-01')).to be_nil
      expect(Date.iso8601('-9999-01-01')).to be_a(Date) # the trap really is a valid Date
    end

    it 'refuses a year outside four digits' do
      expect(described_class.parse_period('26-08-01')).to be_nil
      expect(described_class.parse_period('202608-01')).to be_nil
    end

    it 'refuses an impossible day' do
      expect(described_class.parse_period('2026-02-30')).to be_nil
    end
  end

  describe '.normalise_period' do
    it 'takes a Date to the first of its month' do
      expect(described_class.normalise_period(Date.new(2026, 8, 17))).to eq(Date.new(2026, 8, 1))
    end

    # [CRITICAL] The two-hour trap. 2026-08-01 00:30 Europe/Berlin is
    # 2026-07-31 22:30 UTC, and the app runs on UTC -- a bare `.to_date` answers
    # JULY for a moment that is already August to every customer.
    it 'converts a Time to Europe/Berlin before taking the month' do
      expect(described_class.normalise_period(Time.utc(2026, 7, 31, 22, 30, 0)))
        .to eq(Date.new(2026, 8, 1))
    end

    it 'still answers the old month just before local midnight' do
      expect(described_class.normalise_period(Time.utc(2026, 7, 31, 21, 30, 0)))
        .to eq(Date.new(2026, 7, 1))
    end
  end

  describe '.distinct_user_count' do
    it 'counts users, not pairs' do
      expect(described_class.distinct_user_count([pair_one, pair_two])).to eq(1)
    end
  end
end
