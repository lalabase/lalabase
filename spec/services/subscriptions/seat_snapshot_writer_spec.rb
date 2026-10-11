# frozen_string_literal: true

require 'rails_helper'

# What: the month-boundary snapshot writer (M1a, doc/abrechnungsmodell_plan.md
#       §4 step 1; T18 in doc/billing_agentur_konto_plan.md §17.3).
# Type: service spec.
# Why:  every number M2 will ever put on an invoice starts from these rows. The
#       examples pin the four properties that fail SILENTLY if lost: dedup
#       across organisations (a plus/minus counter looks plausible and is
#       wrong), the Europe/Berlin boundary (a UTC month is off by two hours and
#       nobody notices), NULL instead of zero before the stream opened (§3),
#       and overwrite-on-rerun (write-once here would make the §9 repair --
#       backdated event, recompute -- impossible).
#
# Events are written directly rather than through memberships: the recorder's
# own path is covered by seat_event_recording_spec and the drift spec; here the
# input is the stream itself, and synthetic rows keep every timestamp exact.
RSpec.describe Subscriptions::SeatSnapshotWriter do
  include ActiveSupport::Testing::TimeHelpers

  let(:period) { Date.new(2026, 7, 1) }
  # 2026-07-01 00:00 Europe/Berlin (CEST) as a HARDCODED UTC instant. Never
  # derived from SeatSnapshot.boundary_moment: an expectation computed from the
  # code under test would stay green under any zone.
  let(:boundary_utc) { Time.utc(2026, 6, 30, 22, 0, 0) }
  let(:account) { create(:account) }
  let(:org_one) { { id: SecureRandom.uuid, name: 'Org Eins' } }
  let(:org_two) { { id: SecureRandom.uuid, name: 'Org Zwei' } }
  let(:user_a) { SecureRandom.uuid }
  let(:user_b) { SecureRandom.uuid }

  # Only the stream marker. The account's own creation date is deliberately NOT
  # touched: since the #529 review, reconstructible_from reads the marker alone,
  # because before an account existed it held zero seats and that is a
  # measurement rather than an unknown. Backdating the accounts here would be a
  # dead line pretending to matter.
  def make_reconstructible(*_accounts, from: Time.utc(2026, 1, 1))
    SystemSetting.seat_stream_opened_at!(from)
  end

  def record(account, org:, user_id:, at:, counted: true)
    event = counted ? Subscriptions::Constants::SEAT_EVENT_ACTIVATED : Subscriptions::Constants::SEAT_EVENT_DEACTIVATED
    SeatEvent.create!(account: account, organisation_id: org[:id],
                      organisation_name: org[:name], user_id: user_id,
                      event: event, occurred_at: at, billable: true, counted: counted)
  end

  def snapshot_for(account)
    SeatSnapshot.find_by!(account: account, period_start: period)
  end

  describe 'dedup across organisations (D4.1)' do
    # The same user occupying a seat in TWO organisations of one account is ONE
    # seat but TWO pairs -- the count and the map answer different questions.
    it 'counts one seat but keeps both pairs' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 2.hours)
      record(account, org: org_two, user_id: user_a, at: boundary_utc - 2.hours)

      described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      expect(snapshot.seat_count).to eq(1)
      expect(snapshot.pairs.map { |p| p['organisation_name'] })
        .to contain_exactly('Org Eins', 'Org Zwei')
    end

    # THE case a plus/minus counter gets wrong: leaving org one frees no seat
    # while the user still sits in org two. The pairs are asserted too, because
    # a reconstruction that ignores the deactivation also answers count 1 --
    # with a stale second pair.
    it 'keeps the seat at one when the user leaves one of the two organisations' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 3.hours)
      record(account, org: org_two, user_id: user_a, at: boundary_utc - 3.hours)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 1.hour, counted: false)

      described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      expect(snapshot.seat_count).to eq(1)
      expect(snapshot.pairs.map { |p| p['organisation_name'] }).to eq(['Org Zwei'])
    end
  end

  # Without this the snapshot could drift away from the drift check's own
  # figure and §3's acceptance rule (stream == live) would no longer reach the
  # rows M2 reads. The literal expectation guards against the comparison
  # becoming true by construction.
  it 'says the same thing as the stream reconstruction for the same instant' do
    make_reconstructible(account)
    record(account, org: org_one, user_id: user_a, at: boundary_utc - 3.hours)
    record(account, org: org_two, user_id: user_b, at: boundary_utc - 3.hours)
    record(account, org: org_two, user_id: user_b, at: boundary_utc - 1.hour, counted: false)

    described_class.call(period_start: period)

    snapshot_user_ids = snapshot_for(account).pairs.map { |p| p['user_id'] }.uniq
    expect(snapshot_user_ids).to eq([user_a])
    expect(snapshot_user_ids)
      .to match_array(SeatEvent.counted_user_ids_for(account: account, at: boundary_utc))
  end

  describe 'the boundary is Europe/Berlin, not UTC (A6)' do
    # Both sides of the boundary, half an hour away each. Under a UTC boundary
    # (midnight 1 July UTC) BOTH events lie before it and the count flips to 2
    # -- that is the mutation this example exists to catch.
    it 'includes 23:30 local of the last day and excludes 00:30 local of the first' do
      make_reconstructible(account)
      # 30 June 23:30 Europe/Berlin -- before the boundary.
      record(account, org: org_one, user_id: user_a, at: Time.utc(2026, 6, 30, 21, 30))
      # 1 July 00:30 Europe/Berlin -- after the boundary, but 30 June in UTC.
      record(account, org: org_two, user_id: user_b, at: Time.utc(2026, 6, 30, 22, 30))

      described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      expect(snapshot.seat_count).to eq(1)
      expect(snapshot.pairs.map { |p| p['user_id'] }).to eq([user_a])
    end

    # A7: everything carrying the boundary's exact timestamp is applied, THEN
    # the state is measured -- so the boundary event belongs to the snapshot,
    # and the M2 replay must start strictly after it. Pinned so that contract
    # cannot drift silently.
    it 'includes an event occurring exactly at the boundary instant' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: Time.utc(2026, 6, 30, 22, 0, 0))

      described_class.call(period_start: period)

      expect(snapshot_for(account).seat_count).to eq(1)
    end
  end

  describe 'boundaries before the opening (§3)' do
    it 'writes NULL, not zero, while the backfill has never run' do
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 2.hours)

      result = described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      expect(snapshot).to be_not_reconstructible
      expect(snapshot.seat_count).to be_nil
      expect(snapshot.pairs).to eq([])
      expect(result.not_reconstructible).to eq(1)
    end

    it 'writes NULL for a boundary before the marker' do
      # Marker AFTER the July boundary: the stream opened in August, July is
      # unanswerable even though events exist.
      make_reconstructible(account, from: Time.utc(2026, 8, 1))
      record(account, org: org_one, user_id: user_a, at: Time.utc(2026, 8, 2))

      described_class.call(period_start: period)

      expect(snapshot_for(account)).to be_not_reconstructible
      expect(snapshot_for(account).seat_count).to be_nil
    end
  end

  describe 'recomputable, not write-once (§9)' do
    it 'keeps one row and the same value across a second identical run' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 2.hours)

      described_class.call(period_start: period)
      first = snapshot_for(account)
      described_class.call(period_start: period)

      expect(SeatSnapshot.where(account: account, period_start: period).count).to eq(1)
      expect(snapshot_for(account).id).to eq(first.id)
      expect(snapshot_for(account).seat_count).to eq(1)
    end

    # The half that distinguishes upsert from DO NOTHING: a "no duplicate"
    # assertion alone stays green under DO NOTHING too. §9's repair path is a
    # backdated create! followed by a recompute -- so the recompute MUST be able
    # to change the stored value.
    it 'changes the value when a backdated event is inserted and the period is recomputed' do
      make_reconstructible(account)
      record(account, org: org_one, user_id: user_a, at: boundary_utc - 2.hours)
      described_class.call(period_start: period)
      expect(snapshot_for(account).seat_count).to eq(1)

      # The repair from §9: the missed event arrives late, dated into the past.
      record(account, org: org_two, user_id: user_b, at: boundary_utc - 3.hours)
      described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      expect(snapshot.seat_count).to eq(2)
      expect(snapshot.pairs.map { |p| p['user_id'] }).to contain_exactly(user_a, user_b)
    end
  end

  describe 'failure isolation (T18 point 3)' do
    # One broken account must not cost the others their row -- and the failure
    # itself has to become a ROW, because a log line is gone with the log while
    # the M1b gap check reads the table.
    it 'writes a failed row for the broken account and an ok row for the healthy one' do
      healthy = create(:organisation).account
      make_reconstructible(account, healthy)
      record(healthy, org: org_one, user_id: user_a, at: boundary_utc - 2.hours)
      allow(SeatEvent).to receive(:counted_events_for).and_call_original
      allow(SeatEvent).to receive(:counted_events_for)
        .with(account: account, at: anything)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')

      result = described_class.call(period_start: period)

      failed_row = snapshot_for(account)
      expect(failed_row).to be_failed
      expect(failed_row.error).to include('ActiveRecord::StatementInvalid')
      expect(failed_row.seat_count).to be_nil
      expect(snapshot_for(healthy).seat_count).to eq(1)
      expect(result.failed).to eq(1)
      expect(result.written).to eq(1)
    end
  end

  describe 'deleted organisations (§5)' do
    it 'keeps the frozen name readable although no such organisation exists' do
      make_reconstructible(account)
      record(account, org: { id: SecureRandom.uuid, name: 'Geloeschte GmbH' },
                      user_id: user_a, at: boundary_utc - 2.hours)

      described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      # The premise, stated: the organisation id in the pair resolves to nothing.
      expect(Organisation.exists?(id: snapshot.pairs.sole['organisation_id'])).to be(false)
      expect(snapshot.pairs.sole['organisation_name']).to eq('Geloeschte GmbH')
    end
  end

  describe 'scope and parameters' do
    it 'measures an account without a single seat as 0, distinct from NULL' do
      make_reconstructible(account)

      described_class.call(period_start: period)

      snapshot = snapshot_for(account)
      expect(snapshot).to be_ok
      expect(snapshot.seat_count).to eq(0)
      expect(snapshot.pairs).to eq([])
    end

    it 'writes only the given account when one is passed' do
      other = create(:account)
      make_reconstructible(account, other)

      described_class.call(period_start: period, account: other)

      expect(SeatSnapshot.pluck(:account_id)).to eq([other.id])
    end

    it 'normalises a mid-month date to the first of its month' do
      make_reconstructible(account)

      described_class.call(period_start: Date.new(2026, 7, 15), account: account)

      expect(SeatSnapshot.sole.period_start).to eq(Date.new(2026, 7, 1))
    end

    # [CRITICAL] A Time, not a Date, and that is the whole point: the app runs on
    # UTC while the months are Berlin, so 2026-07-31 22:30 UTC is already August
    # to every customer. A bare `.to_date` here answers JULY and writes the row
    # under the wrong boundary.
    #
    # The Date example above cannot see this -- both readings agree on a Date --
    # so a rebase that dropped the normalisation would have stayed green (the
    # #529 rebase did exactly that, and this is the example that would have
    # caught it).
    it 'reads a Time in Europe/Berlin before naming the month' do
      make_reconstructible(account)

      described_class.call(period_start: Time.utc(2026, 7, 31, 22, 30, 0), account: account)

      expect(SeatSnapshot.sole.period_start).to eq(Date.new(2026, 8, 1))
    end

    # The state at a future boundary does not exist yet; a row written early
    # would freeze "so far" under a date that promises the boundary.
    it 'refuses a future boundary' do
      expect do
        described_class.call(period_start: Date.current.next_month.beginning_of_month)
      end.to raise_error(ArgumentError, /future boundary/)
    end
  end

  # M1b. .call and .fill differ in exactly one thing, and it is the thing the
  # monthly job depends on: .fill must not touch a row that already has an
  # answer, or every §9 correction would be undone at the next tick.
  describe '.fill' do
    before { make_reconstructible(account) }

    it 'leaves an answered row alone where .call would overwrite it' do
      described_class.call(period_start: period)
      SeatSnapshot.for_period(period).update_all(seat_count: 42)

      described_class.fill(period_start: period)

      expect(snapshot_for(account).seat_count).to eq(42)
    end

    it 'still writes an account that has no row yet' do
      other = create(:account)
      make_reconstructible(other)
      described_class.call(period_start: period, account: account)

      result = described_class.fill(period_start: period)

      expect(result.outcomes.map(&:account)).to eq([other])
      expect(SeatSnapshot.for_period(period).count).to eq(2)
    end

    # The same race as on the failure path, one step earlier: the row gained an
    # answer between pending_accounts and the write. find_or_initialize_by loads
    # the other run's row, so this is an UPDATE and the unique index never sees
    # it. Harmless while both runs read the same stream, and not harmless at all
    # when they hold different opening markers.
    it 'writes nothing when the row gained an answer since it was selected' do
      writer = described_class.new(period_start: period, only_unanswered: true)
      allow(writer).to receive(:pending_accounts).and_return([account])
      described_class.call(period_start: period)
      SeatSnapshot.for_period(period).update_all(seat_count: 42)

      result = writer.call

      expect(snapshot_for(account).seat_count).to eq(42)
      # Not counted as written: nobody did that work.
      expect(result.written).to eq(0)
      expect(result.skipped).to eq(1)
    end

    # A failed row is NOT an answer: retrying it is what lets a transient error
    # heal instead of becoming a permanent hole in the table.
    it 'rewrites a failed row' do
      SeatSnapshot.create!(account: account, period_start: period,
                           status: Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED,
                           error: 'kaputt', computed_at: Time.current)

      described_class.fill(period_start: period)

      expect(snapshot_for(account)).to be_ok
    end

    # not_reconstructible IS an answer. Re-asking it every month would rewrite
    # the same rows forever and, worse, would hide the moment it stops being
    # true behind a wall of identical writes.
    it 'leaves a not_reconstructible row alone' do
      SystemSetting.find_by!(key: 'seat_stream_opened_at').destroy!
      described_class.call(period_start: period)
      before_row = snapshot_for(account)
      SystemSetting.seat_stream_opened_at!(Time.utc(2026, 1, 1))

      described_class.fill(period_start: period)

      expect(snapshot_for(account).updated_at).to eq(before_row.updated_at)
      expect(snapshot_for(account)).to be_not_reconstructible
    end
  end

  # A MEASUREMENT is never replaced by a FAILURE. The unique index makes a
  # concurrent double insert impossible, but on its own it only turns the race
  # into an exception in the loser -- whose rescue would then find the winner's
  # row and write a `failed` over it.
  describe 'a failure that meets an existing row' do
    before { make_reconstructible(account) }

    it 'keeps the measured row and still reports the attempt as failed' do
      described_class.call(period_start: period)
      allow(SeatEvent).to receive(:counted_events_for)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')

      result = described_class.call(period_start: period)

      expect(result.failed).to eq(1)
      expect(snapshot_for(account)).to be_ok
      expect(snapshot_for(account).seat_count).to eq(0)
    end

    it 'writes the failure where there is nothing to protect' do
      allow(SeatEvent).to receive(:counted_events_for)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')

      described_class.call(period_start: period)

      expect(snapshot_for(account)).to be_failed
      expect(snapshot_for(account).error).to match(/StatementInvalid/)
    end

    # A failed row is not an answer, so refreshing it loses nothing and keeps
    # the newest error message.
    it 'replaces an older failure with the current one' do
      SeatSnapshot.create!(account: account, period_start: period,
                           status: Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED,
                           error: 'alter Fehler', computed_at: Time.current)
      allow(SeatEvent).to receive(:counted_events_for)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')

      described_class.call(period_start: period)

      expect(snapshot_for(account).error).to match(/kaputt/)
    end

    # It hands out no snapshot when it kept a foreign row. The outcome is about
    # THIS attempt, the row is about what is known, and passing the survivor
    # along would let a reader ask outcome.snapshot.error and get a confident
    # nil where the real reason is.
    it 'reports the reason on the outcome and no row it did not write' do
      described_class.call(period_start: period)
      allow(SeatEvent).to receive(:counted_events_for)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')

      outcome = described_class.call(period_start: period).outcomes.sole

      expect(outcome.snapshot).to be_nil
      expect(outcome.error).to match(/StatementInvalid/)
    end

    # persist_failure runs INSIDE the rescue clause of snapshot_account, so an
    # exception escaping it is caught by nothing: it would take the remaining
    # accounts of the boundary, every later boundary of the run, and the gap
    # report that exists to notice exactly that.
    it 'keeps sweeping when writing the failure row fails too' do
      other = create(:account)
      make_reconstructible(other)
      allow(SeatEvent).to receive(:counted_events_for).and_call_original
      allow(SeatEvent).to receive(:counted_events_for)
        .with(account: account, at: anything)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')
      allow(SeatSnapshot).to receive(:find_or_initialize_by).and_wrap_original do |orig, *args|
        row = orig.call(*args)
        next row unless args.first[:account] == account

        allow(row).to receive(:update!).and_raise(ActiveRecord::RecordNotUnique, 'race')
        row
      end

      result = nil
      expect { result = described_class.call(period_start: period) }.not_to raise_error

      expect(result.failed).to eq(1)
      expect(result.outcomes.find(&:failed?).error).to match(/failure row not written/)
      expect(snapshot_for(other)).to be_ok
    end

    # The race itself: fill selected the account while it was unanswered,
    # another run committed a measurement meanwhile, and our insert hits the
    # unique index. Modelled by handing the writer the stale "no row yet" read
    # that the loser holds.
    it 'does not let a lost insert race erase the winner' do
      writer = described_class.new(period_start: period, only_unanswered: true)
      allow(writer).to receive(:pending_accounts).and_return([account])
      described_class.call(period_start: period)

      calls = 0
      allow(SeatSnapshot).to receive(:find_or_initialize_by).and_wrap_original do |orig, *args|
        calls += 1
        calls == 1 ? SeatSnapshot.new(account: account, period_start: period) : orig.call(*args)
      end

      result = writer.call

      expect(result.failed).to eq(1)
      expect(snapshot_for(account)).to be_ok
    end
  end

  describe '.gaps' do
    let(:current) { described_class.current_boundary_month }

    before do
      make_reconstructible(account, from: 3.years.ago)
      # HERE created_at really matters, unlike in make_reconstructible: the gap
      # watcher filters on it (`created_before`), so the established account has
      # to be older than the cut-off the example below picks. Set explicitly
      # rather than in the shared helper, where it would look like the marker
      # depended on it.
      account.update_column(:created_at, 3.years.ago)
    end

    # The job fills first and asks afterwards; an account created in between is
    # nobody's fault and must not raise the alarm.
    it 'skips an account created after the given moment' do
      newcomer = create(:account)

      gaps = described_class.gaps(months: 0, created_before: 1.minute.ago)

      expect(gaps.map { |gap| gap[:account_id] }).to eq([account.id])
      expect(gaps.map { |gap| gap[:account_id] }).not_to include(newcomer.id)
    end

    # The anchor is a parameter so the job can hand down the one its fill loop
    # used. Re-reading the clock here would let a run that crosses midnight
    # check a boundary the fill never touched and call every account a hole.
    it 'takes its anchor from the caller' do
      gaps = described_class.gaps(months: 0, current: current - 3.months)

      expect(gaps).to eq([{ period_start: current - 3.months, account_id: account.id }])
    end

    it 'names every boundary in the window that has no answer' do
      gaps = described_class.gaps(months: 2)

      expect(gaps).to eq([{ period_start: current, account_id: account.id },
                          { period_start: current - 1.month, account_id: account.id },
                          { period_start: current - 2.months, account_id: account.id }])
    end

    it 'stops naming a boundary once it has an answer' do
      described_class.fill(period_start: current)

      expect(described_class.gaps(months: 2).map { |gap| gap[:period_start] })
        .to eq([current - 1.month, current - 2.months])
    end

    # The watcher and the writer must never disagree about who is still
    # missing, so a failed row has to read as a gap here as well.
    it 'still names a boundary whose only row is a failure' do
      SeatSnapshot.create!(account: account, period_start: current,
                           status: Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED,
                           error: 'kaputt', computed_at: Time.current)

      expect(described_class.gaps(months: 0))
        .to eq([{ period_start: current, account_id: account.id }])
    end
  end

  # The Berlin behaviour itself is pinned once, at its owner
  # (seat_snapshot_spec.rb, `.current_period`). Repeating those two timestamps
  # here would be a second copy of the same rule, free to disagree in exactly the
  # two hours a month it is about. What is left is the wiring.
  describe '.current_boundary_month' do
    it 'answers through the one shared definition' do
      travel_to(Time.utc(2026, 6, 30, 22, 30)) do
        expect(described_class.current_boundary_month).to eq(SeatSnapshot.current_period)
        expect(described_class.current_boundary_month).to eq(Date.new(2026, 7, 1))
      end
    end
  end
end
