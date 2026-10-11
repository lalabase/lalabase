# frozen_string_literal: true

require 'rails_helper'

# What: the monthly boundary snapshot job (M1b, doc/abrechnungsmodell_plan.md
#       §4; T18 in doc/billing_agentur_konto_plan.md §17.3).
# Type: Job spec.
# Why:  three properties that fail silently if lost, plus the log contract.
#
#       1. It FILLS rather than recomputes. A run that overwrote answered rows
#          would undo the §9 repair (backdated event, deliberate rebuild) at the
#          next monthly tick, and nothing would turn red.
#       2. It retries a `failed` row. That is what makes a transient error heal
#          itself instead of sitting in the table as a permanent hole.
#       3. It reaches back, so a missed month is picked up by the next run.
#
#       The log line is pinned including the `[seat_snapshot]` prefix and the
#       LEVEL, because an ops-side watcher matches on both and there is no
#       in-app alerting path. Pinning only the happy line would leave the alarm
#       half renameable without a failing test.
RSpec.describe SeatSnapshotJob do
  let(:account) { create(:account) }
  let(:org) { { id: SecureRandom.uuid, name: 'Org Eins' } }
  let(:user_id) { SecureRandom.uuid }

  # Every boundary in the job's window must be answerable, otherwise the counts
  # in the log line say not_reconstructible and prove nothing about filling.
  def open_the_stream(*accounts, from: 2.years.ago)
    SystemSetting.seat_stream_opened_at!(from)
    accounts.each { |acc| acc.update_column(:created_at, from) }
  end

  def current_period
    Subscriptions::SeatSnapshotWriter.current_boundary_month
  end

  describe 'the clean run' do
    before { open_the_stream(account) }

    it 'answers every boundary in the window, current month included' do
      described_class.perform_now

      periods = SeatSnapshot.where(account: account).pluck(:period_start)
      expected = (0..described_class::CATCH_UP_MONTHS).map { |ago| current_period - ago.months }
      expect(periods).to match_array(expected)
      # The current month is the one AiUsageRollupJob deliberately skips. A
      # snapshot describes an instant, and that instant is already past.
      expect(periods).to include(current_period)
    end

    # Its own example, not a corollary of the window check above: switching the
    # loop to (1..n), the way AiUsageRollupJob deliberately runs, leaves the
    # match_array expectation failing for a reason that reads like an off-by-one
    # and says nothing about WHICH boundary went missing. At 0 the running month
    # is the only thing the job can write, so nothing else can carry the
    # example.
    it 'writes the running month even when it looks back no further' do
      described_class.perform_now(catch_up_months: 0)

      expect(SeatSnapshot.where(account: account).pluck(:period_start)).to eq([current_period])
    end

    # The marker is ONE global value and every boundary of a run must be
    # measured against the same one. Passing it down is also what keeps seven
    # boundaries from re-reading the same system setting seven times -- a hoist
    # that is invisible in the result and would come back silently the moment
    # somebody drops the argument as redundant.
    it 'reads the opening marker once for the whole run' do
      expect(SystemSetting).to receive(:seat_stream_opened_at).once.and_call_original

      described_class.perform_now
    end

    it 'logs at info with the prefix and nothing at error level' do
      allow(Rails.logger).to receive(:info)
      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info)
        .with(/\A\[seat_snapshot\] fill: boundaries=7 written=7 .*failed=0 skipped=0/)
    end
  end

  # Without the marker every account answers not_reconstructible, and that IS an
  # answer: no later run re-asks it, the gap watcher stays quiet, and the
  # summary line reports zero failures on info. One unattended run on a restored
  # database would fill the whole window with a permanent lie and leave nothing
  # to notice it by. Both rake tasks refuse this; the scheduled path is the one
  # nobody watches, so it has to refuse it louder.
  describe 'without an opening marker' do
    it 'writes nothing at all' do
      expect { described_class.perform_now }.to raise_error(described_class::MissingOpeningMarker)

      expect(SeatSnapshot.count).to eq(0)
    end

    it 'fails the execution instead of reporting a quiet success' do
      allow(Rails.logger).to receive(:error)

      expect { described_class.perform_now }.to raise_error(described_class::MissingOpeningMarker)

      expect(Rails.logger).to have_received(:error).with(/\A\[seat_snapshot\] aborted: no opening marker/)
    end
  end

  describe 'filling, not recomputing' do
    before { open_the_stream(account) }

    # THE property that distinguishes the monthly job from `rake
    # seat_snapshots:rebuild`. If this were a recompute, the §9 repair would be
    # undone every month and no test would notice.
    it 'leaves an answered row untouched, even one that disagrees with the stream' do
      described_class.perform_now
      row = SeatSnapshot.find_by!(account: account, period_start: current_period)
      row.update_columns(seat_count: 99, pairs: [{ 'organisation_id' => org[:id],
                                                   'organisation_name' => org[:name],
                                                   'user_id' => user_id }])

      described_class.perform_now

      expect(row.reload.seat_count).to eq(99)
    end

    it 'writes the boundary a previous run missed' do
      missed = current_period - 2.months
      described_class.perform_now
      SeatSnapshot.for_period(missed).delete_all

      described_class.perform_now

      expect(SeatSnapshot.for_period(missed).count).to eq(1)
    end

    # A failed row is not an answer. Retrying it is what turns a one-off
    # database hiccup into a self-healing hole instead of a permanent one.
    it 'retries a failed row and replaces it with a measurement' do
      SeatSnapshot.create!(account: account, period_start: current_period,
                           status: Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_FAILED,
                           error: 'kaputt', computed_at: Time.current)

      described_class.perform_now

      row = SeatSnapshot.find_by!(account: account, period_start: current_period)
      expect(row).to be_ok
      expect(row.error).to be_nil
    end
  end

  describe 'an account whose boundary cannot be computed' do
    let!(:healthy) { create(:account) }

    before do
      open_the_stream(account, healthy)
      allow(SeatEvent).to receive(:counted_events_for).and_call_original
      allow(SeatEvent).to receive(:counted_events_for)
        .with(account: account, at: anything)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')
      allow(Rails.logger).to receive(:error)
    end

    it 'logs at error, names the account, and still answers the healthy one' do
      described_class.perform_now

      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_snapshot\] fill: boundaries=7 .*failed=7/)
      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_snapshot\]\s+failed account=#{account.id} ActiveRecord::StatementInvalid/)
        .at_least(:once)
      expect(SeatSnapshot.where(account: healthy).count).to eq(7)
    end

    it 'does not raise' do
      expect { described_class.perform_now }.not_to raise_error
    end

    # A silent cap reads as "that was all of them".
    it 'says so when it stops naming' do
      stub_const('Subscriptions::Constants::SEAT_SNAPSHOT_MAX_NAMED', 2)

      described_class.perform_now

      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_snapshot\]\s+named 2 of 7 failures, rest omitted/)
    end
  end

  # Reaching the gap line means the fill ran and the boundary STILL has no
  # answer, so the write itself could not even produce a failed row. Rare, and
  # exactly the case that would otherwise surface on an invoice.
  describe 'the gap watcher' do
    before { open_the_stream(account) }

    it 'reports a boundary that stayed unanswered after the fill' do
      allow(Subscriptions::SeatSnapshotWriter).to receive(:fill)
        .and_return(Subscriptions::SeatSnapshotWriter::Result.new(period_start: current_period,
                                                                  outcomes: []))
      allow(Rails.logger).to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:error)
        .with(%r{\A\[seat_snapshot\] 7 boundary/account pair\(s\) still without an answer:})
    end

    it 'stays quiet when every boundary was answered' do
      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now
    end

    # The watcher must look at exactly the window the fill just wrote. A hard
    # coded CATCH_UP_MONTHS on either side would pass every example where the
    # two happen to be equal, and then report holes nobody ever fills.
    it 'checks the same window the fill covered, not a fixed one' do
      allow(Subscriptions::SeatSnapshotWriter).to receive(:fill)
        .and_return(Subscriptions::SeatSnapshotWriter::Result.new(period_start: current_period,
                                                                  outcomes: []))
      allow(Rails.logger).to receive(:error)

      described_class.perform_now(catch_up_months: 1)

      expect(Rails.logger).to have_received(:error)
        .with(%r{\A\[seat_snapshot\] 2 boundary/account pair\(s\)})
    end

    # Same reason the failure list says when it truncates: a capped list that
    # does not admit it reads as the complete one.
    it 'says so when it stops naming gaps' do
      stub_const('Subscriptions::Constants::SEAT_SNAPSHOT_MAX_NAMED', 2)
      allow(Subscriptions::SeatSnapshotWriter).to receive(:fill)
        .and_return(Subscriptions::SeatSnapshotWriter::Result.new(period_start: current_period,
                                                                  outcomes: []))
      allow(Rails.logger).to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(/, named 2 of 7\z/)
    end

    # Every new organisation gets an account (AccountAutoAssignable), so a
    # signup landing inside a run is routine. It has no answer for any boundary
    # and nothing went wrong: the fill loop ran before it existed, and the next
    # run picks it up.
    it 'ignores an account that appeared after the fill loop' do
      expect(Rails.logger).not_to receive(:error)
      allow(Subscriptions::SeatSnapshotWriter).to receive(:gaps).and_wrap_original do |orig, **kwargs|
        create(:account)
        orig.call(**kwargs)
      end

      described_class.perform_now
    end
  end
end
