# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the three operator tasks of the month-boundary snapshots (M1b,
#       doc/abrechnungsmodell_plan.md §4).
# Type: Rake task spec.
# Why:  each carries a property the service underneath does not, and each one is
#       wiring that no service spec can see.
#
#       backfill must refuse to run without an opening marker, and must not
#       invent boundaries before it. rebuild is the ONLY deliberate recompute
#       path and has to exit non-zero when it leaves a boundary unanswered --
#       it overwrote the previous row to get there, so a quiet failure is worse
#       than no run at all.
RSpec.describe 'seat_snapshots tasks' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('seat_snapshots:gaps')
  end

  before do
    %w[backfill gaps rebuild].each { |name| Rake::Task["seat_snapshots:#{name}"].reenable }
  end

  let!(:account) { create(:account) }

  def current_period
    Subscriptions::SeatSnapshotWriter.current_boundary_month
  end

  describe 'seat_snapshots:backfill' do
    # Without a marker nothing is reconstructible, so a run would write
    # "cannot be known" for every boundary it touched and call that a backfill.
    it 'aborts when the stream was never opened' do
      expect { Rake::Task['seat_snapshots:backfill'].invoke }
        .to raise_error(SystemExit)
        .and output(/Es gibt keinen Eroeffnungsstand/).to_stderr
    end

    it 'writes every boundary after the marker month' do
      SystemSetting.seat_stream_opened_at!(3.months.ago)
      account.update_column(:created_at, 3.months.ago)

      expect { Rake::Task['seat_snapshots:backfill'].invoke }
        .to output(%r{Grenze/Konto-Paar\(e\) neu beantwortet}).to_stdout

      expect(SeatSnapshot.where(account: account).count).to be >= 2
      # The marker's own month is excluded: its boundary is midnight, the
      # marker arrived later that month, so it is not reconstructible.
      expect(SeatSnapshot.chronological.first.period_start)
        .to eq(3.months.ago.to_date.beginning_of_month.next_month)
    end

    it 'says so when the marker month has not ended yet' do
      SystemSetting.seat_stream_opened_at!(Time.current)

      expect { Rake::Task['seat_snapshots:backfill'].invoke }
        .to output(/Noch keine abgeschlossene Monatsgrenze/).to_stdout

      expect(SeatSnapshot.count).to eq(0)
    end
  end

  describe 'seat_snapshots:gaps' do
    it 'reports the boundaries without an answer' do
      expect { Rake::Task['seat_snapshots:gaps'].invoke('1') }
        .to output(/2 Luecke\(n\)/).to_stdout
    end

    it 'stays quiet once they are answered' do
      SystemSetting.seat_stream_opened_at!(2.years.ago)
      account.update_column(:created_at, 2.years.ago)
      Subscriptions::SeatSnapshotWriter.fill(period_start: current_period)
      Subscriptions::SeatSnapshotWriter.fill(period_start: current_period - 1.month)

      expect { Rake::Task['seat_snapshots:gaps'].invoke('1') }
        .to output(/keine Luecken/).to_stdout
    end
  end

  describe 'seat_snapshots:rebuild' do
    before do
      SystemSetting.seat_stream_opened_at!(2.years.ago)
      account.update_column(:created_at, 2.years.ago)
    end

    it 'refuses without a period' do
      expect { Rake::Task['seat_snapshots:rebuild'].invoke }
        .to raise_error(SystemExit)
        .and output(/Nutzung: rake/).to_stderr
    end

    # The destructive task must not be the one without the precondition:
    # without a marker nothing is reconstructible, so the run would replace
    # every measured row of the boundary with "cannot be known" and say it
    # succeeded.
    it 'refuses when the stream was never opened, without touching the rows' do
      Subscriptions::SeatSnapshotWriter.call(period_start: current_period)
      SystemSetting.find_by!(key: 'seat_stream_opened_at').destroy!

      expect { Rake::Task['seat_snapshots:rebuild'].invoke(current_period.to_s) }
        .to raise_error(SystemExit)
        .and output(/Es gibt keinen Eroeffnungsstand/).to_stderr

      expect(SeatSnapshot.for_period(current_period).sole).to be_ok
    end

    it 'refuses a period that is not a date' do
      expect { Rake::Task['seat_snapshots:rebuild'].invoke('morgen') }
        .to raise_error(SystemExit)
        .and output(/ist kein Datum/).to_stderr
    end

    # This is the only task that overwrites an answered row, so it must rebuild
    # the boundary the operator NAMED. Date.parse reads "09-01-2026" as the 9th
    # of JANUARY and would silently correct a boundary eight months away from
    # the one that was typed. A date that is merely unparseable does not carry
    # this example: it fails under every reader.
    it 'refuses a date whose fields could be read in another order' do
      expect { Rake::Task['seat_snapshots:rebuild'].invoke('09-01-2026') }
        .to raise_error(SystemExit)
        .and output(/ist kein Datum im Format JJJJ-MM-TT/).to_stderr

      expect(SeatSnapshot.count).to eq(0)
    end

    # A typo in the year is the normal way to name a boundary that has not
    # happened yet, and it deserves the same one-line German answer as every
    # other refusal of this task.
    it 'answers a future boundary in one German line' do
      expect { Rake::Task['seat_snapshots:rebuild'].invoke((current_period + 2.months).to_s) }
        .to raise_error(SystemExit)
        .and output(/liegt in der Zukunft/).to_stderr
    end

    # Since the writer stopped overwriting an answered row with a failure, the
    # row's `error` column stays empty, so the log line is the ONLY place the
    # operator can learn which account failed and why. "Details im Log" has to
    # be true.
    it 'names the failed account in the log it points at' do
      Subscriptions::SeatSnapshotWriter.call(period_start: current_period)
      allow(SeatEvent).to receive(:counted_events_for)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')
      allow(Rails.logger).to receive(:error)

      expect { Rake::Task['seat_snapshots:rebuild'].invoke(current_period.to_s) }
        .to raise_error(SystemExit)
        .and output(/Details im Log/).to_stderr

      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_snapshot\]\s+failed account=#{account.id} ActiveRecord::StatementInvalid/)
    end

    # A hand-made correction of the billing basis is exactly what an ops-side
    # watcher should see, and it matches on the prefix.
    it 'logs the correction under the watched prefix' do
      allow(Rails.logger).to receive(:warn)

      expect { Rake::Task['seat_snapshots:rebuild'].invoke(current_period.to_s) }
        .to output(/neu gerechnet/).to_stdout

      expect(Rails.logger).to have_received(:warn).with(/\A\[seat_snapshot\] rebuild: /)
    end

    # The difference to the monthly job, in one example: rebuild DOES overwrite
    # an answered row. That is the §9 repair path, and it is the reason the job
    # must not share this entry point.
    it 'overwrites an answered row' do
      Subscriptions::SeatSnapshotWriter.fill(period_start: current_period)
      SeatSnapshot.for_period(current_period).update_all(seat_count: 42)

      expect { Rake::Task['seat_snapshots:rebuild'].invoke(current_period.to_s) }
        .to output(/neu gerechnet/).to_stdout

      expect(SeatSnapshot.for_period(current_period).sole.seat_count).to eq(0)
    end

    # It already overwrote the old row to get here, so exiting 0 would leave the
    # boundary with no answer and nobody looking.
    it 'exits non-zero when an account could not be computed' do
      allow(SeatEvent).to receive(:counted_events_for)
        .and_raise(ActiveRecord::StatementInvalid, 'kaputt')

      expect { Rake::Task['seat_snapshots:rebuild'].invoke(current_period.to_s) }
        .to raise_error(SystemExit)
        .and output(/Mindestens ein Konto konnte nicht gerechnet werden/).to_stderr
    end
  end
end
