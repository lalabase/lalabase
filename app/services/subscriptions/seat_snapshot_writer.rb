# frozen_string_literal: true

# Computes and writes SeatSnapshot rows: the seat state per account at ONE
# measurement-month boundary (M1a, doc/abrechnungsmodell_plan.md §4 step 1; T18
# in doc/billing_agentur_konto_plan.md §17.3).
#
# The period is a PARAMETER, never Time.current (17.3 point 2): a missed month
# is a rerun with an old date, and that only works against the event log --
# against the live state a past boundary is not computable at all.
#
# OVERWRITES on rerun, deliberately -- see the SeatSnapshot model header for why
# this is the exact opposite of AiUsageAggregator's ON CONFLICT DO NOTHING. The
# write goes through find_or_initialize + update! rather than insert_all: the
# overwrite IS the point (a backdated event correction must be able to change
# the value, §9), and the row carries a consistency invariant that a raw upsert
# would write past.
#
# With ONE exception, and it is the only thing this class refuses outright: a
# MEASUREMENT is never overwritten by a FAILURE (see #persist_failure). The
# unique index on (account_id, period_start) makes a concurrent double insert
# impossible, but on its own it only converts that race into an exception in the
# loser -- whose rescue would then find the winner's row and write a `failed`
# over it. Losing a measurement to a crash is strictly worse than keeping a
# possibly stale one: the operator learns of the failure through the outcome
# either way, and a boundary WITHOUT an answer is what the gap watcher exists to
# scream about.
#
# Because overwriting is the normal mode, the two callers must NOT be the same
# entry point: .call recomputes everything (correction), .fill only writes what
# has no answer yet (the monthly job). See the class methods.
module Subscriptions
  class SeatSnapshotWriter
    # One line per account, so M1b can build its log line (written /
    # not reconstructible / failed / skipped) without re-deriving anything.
    #
    # An outcome describes THIS ATTEMPT, the row describes what is known. The
    # two can legitimately disagree, and where they do, `snapshot` is nil: a
    # failed attempt that found an already answered row leaves that row alone
    # (see #persist_failure) and must not hand it out as if this run had
    # produced it. `error` therefore carries the reason on its own rather than
    # through the row, which is also the only place it survives when no row was
    # written.
    Outcome = Struct.new(:account, :status, :snapshot, :error, keyword_init: true) do
      def ok?
        status == Constants::SEAT_SNAPSHOT_STATUS_OK
      end

      def not_reconstructible?
        status == Constants::SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE
      end

      def failed?
        status == Constants::SEAT_SNAPSHOT_STATUS_FAILED
      end

      # Computed, then not written because the row gained an answer meanwhile.
      def skipped?
        status == Constants::SEAT_SNAPSHOT_OUTCOME_SKIPPED
      end
    end

    Result = Struct.new(:period_start, :outcomes, keyword_init: true) do
      def written
        outcomes.count(&:ok?)
      end

      def not_reconstructible
        outcomes.count(&:not_reconstructible?)
      end

      def failed
        outcomes.count(&:failed?)
      end

      def skipped
        outcomes.count(&:skipped?)
      end

      def failures
        outcomes.select(&:failed?)
      end
    end

    class << self
      # RECOMPUTE: writes every account of the boundary, overwriting whatever is
      # already there. The deliberate correction path after a backdated event was
      # added (§9), and what `rake seat_snapshots:rebuild` runs.
      def call(**kwargs)
        new(**kwargs).call
      end

      # FILL: writes only the accounts whose boundary has no ANSWER yet, meaning
      # no row at all or a `failed` one from an earlier attempt. The scheduled
      # job's entry point (M1b).
      #
      # Two named entry points rather than one with a flag, for the same reason
      # AiUsageAggregator has .call and .flush_for: the difference is not a
      # setting somebody tunes, it is which of two callers is asking. And a
      # monthly sweep that overwrote every answered row would rewrite the whole
      # table every month for no new information.
      def fill(period_start:, opened_at: SystemSetting.seat_stream_opened_at)
        new(period_start: period_start, only_unanswered: true, opened_at: opened_at).call
      end

      # Gap watcher (17.3 point 4): which account has no answer for which
      # boundary, across a window of months. The alarm has to name the hole, not
      # the job -- "the run did not log" surfaces an outage two months later, on
      # an invoice.
      #
      # Asks through the SAME unanswered_accounts the fill uses. A second,
      # separate notion of "still missing" would be free to disagree with the one
      # that actually writes, and then the watcher reports holes the job will
      # never fill, or stays quiet about ones it skipped.
      #
      # `months` has no default on purpose: the window is the caller's decision
      # (the job's schedule, the operator's question), and a default here would
      # quietly become a second answer next to SeatSnapshotJob::CATCH_UP_MONTHS.
      #
      # `created_before` exists for the caller that FILLED first and asks
      # afterwards. An account created between the two steps has no answer for
      # any boundary, through nobody's fault, and reporting it would raise the
      # alarm on every signup that happens to land inside a run. Every new
      # organisation gets an account (AccountAutoAssignable), so that is a
      # routine event, not a corner case. Left nil the watcher asks about every
      # account, which is what an operator running the rake task wants.
      # Names the accounts whose boundary could not be computed AT ALL, one line
      # each, capped and saying so when it caps.
      #
      # Lives here rather than in the job because BOTH callers need it and for
      # the same reason: since #persist_failure stopped overwriting an answered
      # row, a failure does not necessarily leave a trace in the table, so the
      # log line is the only place the reason survives. The rebuild task learned
      # that the hard way -- it promised "details in the log" while writing none.
      def log_failures(results, logger: Rails.logger)
        # NOT Array(results): a Struct answers to_a with its MEMBERS, so a
        # single Result would silently become [period_start, outcomes] and the
        # flat_map below would ask a Date for its failures.
        failures = (results.is_a?(Result) ? [results] : results).flat_map(&:failures)
        return if failures.empty?

        max = Constants::SEAT_SNAPSHOT_MAX_NAMED
        failures.first(max).each do |outcome|
          logger.error("#{Constants::SEAT_SNAPSHOT_LOG_PREFIX}   failed " \
                       "account=#{outcome.account.id} #{outcome.error}")
        end
        return if failures.size <= max

        logger.error("#{Constants::SEAT_SNAPSHOT_LOG_PREFIX}   named #{max} of " \
                     "#{failures.size} failures, rest omitted")
      end

      # `current` is the anchor of the window, a parameter for the same reason
      # `opened_at` is one: the caller may already hold it. The job fills from
      # its own anchor and then asks here; re-reading the clock would let a run
      # that crosses midnight check a boundary the fill never wrote and report
      # every account as a hole.
      def gaps(months:, created_before: nil, current: current_boundary_month)
        (0..months).flat_map do |ago|
          period = current - ago.months
          unanswered_accounts(period_start: period, created_before: created_before)
            .map { |account| { period_start: period, account_id: account.id } }
        end
      end

      # THE definition of "this boundary still has no answer for this account":
      # no row at all, or a `failed` one. A class method rather than something
      # the watcher reaches through an instance, because building a writer just
      # to ask a question also resolves the opening marker -- seven boundaries
      # would re-read the same system setting seven times for an answer that
      # never uses it.
      def unanswered_accounts(period_start:, created_before: nil)
        scope = ::Account.where.not(
          id: SeatSnapshot.for_period(period_start).answered.select(:account_id)
        )
        scope = scope.where(created_at: ...created_before) if created_before
        scope.to_a
      end

      # The month the CURRENT boundary belongs to, read in Europe/Berlin (A6).
      # Time.current is UTC, so between midnight and 02:00 Berlin on the 1st a
      # naive reading still names the previous month, and the job would skip the
      # very boundary it woke up for.
      #
      # Points at SeatSnapshot instead of repeating that conversion. The name
      # stays, because the callers here speak of boundaries, but there is ONE
      # implementation and one pair of examples for it (seat_snapshot_spec,
      # `.current_period`) rather than two that could disagree in exactly those
      # two hours a month.
      def current_boundary_month
        SeatSnapshot.current_period
      end
    end

    # account: nil sweeps the accounts of the boundary; a loaded account
    # restricts the run to that one. Normalised to the month's first day, same as
    # AiUsageAggregator, so a mid-month date names the month it lies in.
    #
    # opened_at is the ONE global marker (SeatEvent.reconstructible_from), read
    # once here rather than once per account -- same hoist as SeatStreamDrift.
    # It is a parameter and not just a lookup because a CALLER may loop too: the
    # monthly job walks seven boundaries and would otherwise re-read the same
    # system setting seven times. Passing it keeps the hoist correct one level
    # up, exactly as SeatEvent.reconstructible_from already allows.
    def initialize(period_start:, account: nil, only_unanswered: false,
                   opened_at: SystemSetting.seat_stream_opened_at)
      # Through SeatSnapshot, not a bare .to_date: on a Time that would answer
      # the PREVIOUS month for the first two hours of every month, because the
      # app runs on UTC while the months are Berlin (same reason as
      # SeatSnapshot.current_period).
      @period_start = SeatSnapshot.normalise_period(period_start)
      @account = account
      @only_unanswered = only_unanswered
      @opened_at = opened_at
    end

    def call
      refuse_future_boundary!(boundary)

      outcomes = pending_accounts.map { |account| snapshot_account(account, boundary, @opened_at) }

      Result.new(period_start: @period_start, outcomes: outcomes)
    end

    # Which accounts this run will write.
    #
    # Deliberately NOT filtered to accounts that already existed at the boundary.
    # Skipping them would look tidier -- no rows for months a customer did not
    # have yet -- but it makes "we never asked" indistinguishable from "the write
    # failed", and the gap watcher reads exactly that difference. An account
    # younger than the boundary answers not_reconstructible through
    # SeatEvent.reconstructible_from, which is both true and visible. The tidier
    # version would leave the first, partial month of every new customer as a
    # hole in the table, and M2 needs a row there.
    def pending_accounts
      return [@account] if @account
      return ::Account.all.to_a unless @only_unanswered

      self.class.unanswered_accounts(period_start: @period_start)
    end

    private

    def boundary
      @boundary ||= SeatSnapshot.boundary_moment(@period_start)
    end

    # A snapshot describes the state AT the boundary; before that instant the
    # answer does not exist yet, and a row written early would freeze "the state
    # so far" under a date that promises the boundary. Same shape as
    # AiUsageAggregator.closed_period?, but about the boundary rather than the
    # closed month: the RUNNING month's own opening boundary is already in the
    # past and fine to compute.
    def refuse_future_boundary!(boundary)
      return if boundary <= Time.current

      raise ArgumentError, "refusing to snapshot the future boundary #{@period_start}: " \
                           'the state at that instant does not exist yet'
    end

    # rescue per account (T18 point 3): in a sweep over every account, one
    # broken account must not cost the others their row, and the failure itself
    # becomes a `failed` ROW rather than only a log line. SeatCounter's D7 (NO
    # rescue per organisation) stays untouched -- for the live count failing
    # loudly beats silently under-counting; in a batch it is the wrong way
    # round. Two contexts, two right answers, not a contradiction.
    def snapshot_account(account, boundary, opened_at)
      from = SeatEvent.reconstructible_from(account, opened_at: opened_at)
      return persist_outcome(account, Constants::SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE) if from.nil? || boundary < from

      pairs = occupied_pairs(account, boundary)
      persist_outcome(account, Constants::SEAT_SNAPSHOT_STATUS_OK,
                      seat_count: SeatSnapshot.distinct_user_count(pairs), pairs: pairs)
    rescue StandardError => e
      persist_failure(account, "#{e.class}: #{e.message}")
    end

    # The pairs, straight from the ONE reconstruction seam, shaped by the ONE
    # pair builder (SeatSnapshot.pair_from) that the M2 replay uses too.
    def occupied_pairs(account, boundary)
      SeatEvent.counted_events_for(account: account, at: boundary)
               .map { |event| SeatSnapshot.pair_from(event) }
    end

    def persist_outcome(account, status, seat_count: nil, pairs: [], error: nil)
      row = SeatSnapshot.find_or_initialize_by(account: account, period_start: @period_start)
      return skipped_outcome(account) if fill_must_not_touch?(row)

      row.update!(status: status, seat_count: seat_count, pairs: pairs, error: error,
                  computed_at: Time.current)
      Outcome.new(account: account, status: status, snapshot: row, error: error)
    end

    # In FILL mode a row that gained an answer between pending_accounts and this
    # write belongs to whoever wrote it. The unique index cannot see this case:
    # find_or_initialize_by loads the other run's row, so the write is an UPDATE
    # and passes without complaint.
    #
    # Harmless while both runs read the same append-only stream, and not
    # harmless at all when they hold different `opened_at` -- an older run
    # would put not_reconstructible over a measurement, and since that counts
    # as an ANSWER nothing would ever re-ask it. In RECOMPUTE mode the
    # overwrite is the whole point, so the guard is bound to the mode rather
    # than to the row.
    def fill_must_not_touch?(row)
      @only_unanswered && row.persisted? && row.answered?
    end

    # Nothing was written, and this is not `ok`: counting a write that did not
    # happen would inflate the summary line with work nobody did.
    def skipped_outcome(account)
      Outcome.new(account: account, status: Constants::SEAT_SNAPSHOT_OUTCOME_SKIPPED,
                  snapshot: nil, error: nil)
    end

    # The one write this class refuses: replacing an ANSWERED row with a
    # failure. Two ways in, and the guard is right for both.
    #
    # Concurrency: two runs pick the same unanswered boundary, the winner
    # commits, the loser's insert hits the unique index, and its rescue arrives
    # here holding a RecordNotUnique -- with the winner's measurement now
    # visible to it. Without the guard the loser would erase it, and .fill would
    # have overwritten an answered row after all.
    #
    # Correction: `rake seat_snapshots:rebuild` on a boundary whose recompute
    # crashes. Keeping the old, possibly stale row beats destroying it for a
    # value nobody has; the task still exits non-zero, because the OUTCOME is a
    # failure regardless of what the table now holds.
    #
    # The outcome therefore reports `failed` in both cases, and hands out NO
    # snapshot when it kept a foreign row: the outcome is about THIS attempt,
    # the row is about what is known, and passing the survivor along would let a
    # reader ask `outcome.snapshot.error` and get a confident nil.
    #
    # THIS METHOD MUST NOT RAISE. It runs inside the rescue clause of
    # snapshot_account, so an exception escaping here is not caught by anything:
    # it would take the remaining accounts of this boundary, every later
    # boundary of the run, and the gap report that exists to notice exactly that
    # -- which is the opposite of the per-account rescue T18 asks for. Losing
    # the second insert race is a real way to get here, so the write itself is
    # guarded and its failure is folded into the error text instead.
    def persist_failure(account, error)
      row = SeatSnapshot.find_or_initialize_by(account: account, period_start: @period_start)
      return failure_outcome(account, error, snapshot: nil) if row.persisted? && row.answered?

      row.update!(status: Constants::SEAT_SNAPSHOT_STATUS_FAILED, seat_count: nil, pairs: [],
                  error: error, computed_at: Time.current)
      failure_outcome(account, error, snapshot: row)
    rescue StandardError => e
      failure_outcome(account, "#{error} (failure row not written: #{e.class})", snapshot: nil)
    end

    def failure_outcome(account, error, snapshot:)
      Outcome.new(account: account, status: Constants::SEAT_SNAPSHOT_STATUS_FAILED,
                  snapshot: snapshot, error: error)
    end
  end
end
