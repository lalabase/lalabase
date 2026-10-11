# frozen_string_literal: true

# Monthly: lay down the seat state at each measurement-month boundary (M1b,
# doc/abrechnungsmodell_plan.md §4 step 1; T18 in
# doc/billing_agentur_konto_plan.md §17.3). The peak evaluation (M2) replays a
# month starting from these rows instead of walking the whole event history.
#
# FILLS, DOES NOT RECOMPUTE. Every run writes only the boundaries that have no
# answer yet -- a missing row, or a `failed` one from an earlier attempt. That
# makes a missed run self-healing (the next one picks the boundary up) and a
# transient per-account failure self-healing too, while leaving an answered row
# alone. Recomputing after a backdated event correction is a deliberate,
# separate act: `rake seat_snapshots:rebuild`.
#
# IT INCLUDES THE RUNNING MONTH, unlike AiUsageRollupJob, and the difference is
# not an oversight. A rollup sums a month and is only complete once the month
# has ended. A snapshot describes a single INSTANT, the moment the month began,
# and that instant is in the past from the first second of the month. Waiting
# would leave the current month unopened for up to 31 days for no gain.
#
# LOGS, DOES NOT RAISE for findings. Per-account failures are already held as
# `failed` rows by the writer; what is left for the log is the summary and the
# gaps. There is no in-app alerting path in this project, so an ops-side watcher
# matches on the `[seat_snapshot]` prefix and on the level -- both are part of
# the contract and pinned by the spec. A genuine infrastructure error (no
# database at all) is NOT caught here and becomes a failed execution, which is
# correct: that is not a finding, it is an outage.
#
# IT DOES RAISE for one thing, and it is not a finding either: a missing opening
# marker. That is a precondition, not a result, and writing anything at all
# without it would be permanent (see #refuse_without_marker!).
class SeatSnapshotJob < ApplicationJob
  queue_as :default

  # How far back each run looks for unanswered boundaries. Six months matches
  # AiUsageRollupJob, so the two billing histories cover the same window and an
  # operator does not have to remember two numbers.
  CATCH_UP_MONTHS = 6

  # Raised instead of writing a window full of "cannot be known". See
  # #refuse_without_marker!.
  class MissingOpeningMarker < StandardError; end

  def perform(catch_up_months: CATCH_UP_MONTHS)
    started_at = Time.current
    current = Subscriptions::SeatSnapshotWriter.current_boundary_month
    # Read once for the whole run. Seven boundaries asking the same system
    # setting seven times is the loop the writer's own hoist cannot see.
    opened_at = SystemSetting.seat_stream_opened_at
    refuse_without_marker!(opened_at)

    results = (0..catch_up_months).map do |months_ago|
      Subscriptions::SeatSnapshotWriter.fill(period_start: current - months_ago.months,
                                             opened_at: opened_at)
    end

    log_summary(results)
    Subscriptions::SeatSnapshotWriter.log_failures(results)
    report_gaps(catch_up_months, current, started_at)
  end

  private

  # Without the marker EVERY account answers not_reconstructible, and that is an
  # ANSWER: no later run re-asks it, the gap watcher stays quiet, and the
  # summary line reports zero failures on `info`. One unattended run on a
  # restored or freshly built database would therefore fill the entire window
  # with a permanent lie and leave nothing behind to notice it by.
  #
  # Both rake tasks already refuse this. The scheduled path is the one nobody is
  # watching, so it has to refuse it LOUDER, not quieter: an error line for the
  # ops-side watcher AND a failed execution, because a run that could not do its
  # job must not look like one that had nothing to do.
  def refuse_without_marker!(opened_at)
    return if opened_at

    message = 'no opening marker (SystemSetting seat_stream_opened_at); refusing to write ' \
              'a window of not_reconstructible rows that nothing would ever re-ask'
    Rails.logger.error("#{Subscriptions::Constants::SEAT_SNAPSHOT_LOG_PREFIX} aborted: #{message}")
    raise MissingOpeningMarker, message
  end

  def log_summary(results)
    # `skipped` is separate from `written` on purpose: it counts boundaries this
    # run computed and then did NOT write because a concurrent run had already
    # answered them. Folding it into `written` would report work nobody did.
    line = "#{prefix} fill: boundaries=#{results.size} written=#{results.sum(&:written)} " \
           "not_reconstructible=#{results.sum(&:not_reconstructible)} " \
           "failed=#{results.sum(&:failed)} skipped=#{results.sum(&:skipped)}"

    # A failed row means one account's boundary could not be computed at all.
    # That is the only outcome here that needs a person: an unanswered boundary
    # the next run will retry is not an alarm, and a not_reconstructible one is
    # a measurement.
    return Rails.logger.info(line) if results.sum(&:failed).zero?

    Rails.logger.error(line)
  end

  # Reaching this means a boundary still has no answer after the fill above ran.
  # The fill just tried, so this is not "the job never ran" -- it is an account
  # whose write itself failed in a way that could not even produce a `failed`
  # row. Rare, and exactly the case that would otherwise surface on an invoice.
  #
  # Restricted to accounts that already existed when this run STARTED. One
  # created since has no answer for any boundary and nothing went wrong -- the
  # fill loop simply ran before it did, and the next run picks it up. Without
  # this the alarm would fire on every signup landing inside a run.
  #
  # `current` is the fill loop's OWN anchor, handed down rather than re-read.
  # A run crossing midnight would otherwise check a boundary the fill never
  # touched and report every account of it as a hole.
  def report_gaps(catch_up_months, current, started_at)
    gaps = Subscriptions::SeatSnapshotWriter.gaps(months: catch_up_months,
                                                  created_before: started_at,
                                                  current: current)
    return if gaps.empty?

    max = Subscriptions::Constants::SEAT_SNAPSHOT_MAX_NAMED
    named = gaps.first(max)
                .map { |gap| "#{gap[:period_start]}/#{gap[:account_id]}" }
                .join(', ')
    suffix = gaps.size > max ? ", named #{max} of #{gaps.size}" : ''

    Rails.logger.error(
      "#{prefix} #{gaps.size} boundary/account pair(s) still without an answer: " \
      "#{named}#{suffix}"
    )
  end

  def prefix
    Subscriptions::Constants::SEAT_SNAPSHOT_LOG_PREFIX
  end
end
