# frozen_string_literal: true

# Nightly: does the seat event stream still agree with the live count? (M0c,
# doc/abrechnungsmodell_plan.md §3.)
#
# WHY IT RECURS rather than running once. The backfill's own check proves the
# state at the moment of the backfill and nothing about tomorrow. The stream is
# written by callbacks, and a callback covers only the writes it is attached to:
# the Role#billable flip needed its own recorder, and deleting a role is still
# blind and ASYMMETRIC (::Role nullifies its memberships without an event, while
# Admin::Role destroys them and writes `removed`). The next gap of that shape
# will be found by this job or by a wrong invoice, and those are the only two
# options.
#
# LOGS, DOES NOT RAISE. Not because a raise would retry -- it would not; retries
# are opt-in per job class here (see EmailDeliveryJob) and this class declares
# none, so a raise produces exactly one solid_queue_failed_executions row. The
# reason is that a failed execution is a row in a table nobody watches, while the
# log line is what an ops-side watcher matches on. There is no in-app alerting
# path in this project. A finding that only existed as a failed job would be a
# finding nobody sees.
#
# It also never writes. Repairing would mean inventing the moment at which the
# change happened, and inventing timestamps in an append-only billing ledger is
# how a wrong number becomes an authoritative one.
class SeatStreamDriftCheckJob < ApplicationJob
  queue_as :default

  # Bounds the log line, not the check. Every account is examined; only the
  # naming stops here, because a hundred names in one line help nobody. When it
  # truncates it SAYS so -- a silent cap reads as "that was all of them".
  MAX_NAMED = 10

  def perform
    findings = Subscriptions::SeatStreamDrift.call
    return log_clean if findings.empty?

    log_findings(findings)
  end

  private

  def log_clean
    Rails.logger.info(
      "[seat_stream] drift check: ok accounts=#{::Account.count} " \
      'mismatches=0 unopened=0 errors=0'
    )
  end

  # Three counts, three reactions: a mismatch wants a person, an unopened account
  # wants `rake seat_events:backfill_openings`, and an error wants whoever broke
  # that account's data.
  #
  # Severity follows that split. Only a mismatch is an error, because only a
  # mismatch means the ledger disagrees with reality. An unopened account is a
  # missing setup step, and putting it at error level would build exactly the
  # every-night alarm that staging was excluded to avoid.
  def log_findings(findings)
    failed, rest = findings.partition(&:failed?)
    unopened, mismatches = rest.partition(&:not_reconstructible?)

    log_header(findings, mismatches, unopened, failed)
    log_mismatches(mismatches)
    log_failures(failed)
    log_unopened(unopened)
  end

  def log_header(findings, mismatches, unopened, failed)
    level = mismatches.any? || failed.any? ? :error : :warn
    verdict = level == :error ? 'FAILED' : 'incomplete'

    Rails.logger.public_send(
      level,
      "[seat_stream] drift check: #{verdict} accounts=#{::Account.count} " \
      "mismatches=#{mismatches.size} unopened=#{unopened.size} errors=#{failed.size} " \
      "findings=#{findings.size}"
    )
  end

  def log_mismatches(mismatches)
    mismatches.first(MAX_NAMED).each do |finding|
      Rails.logger.error(
        "[seat_stream]   mismatch account=#{finding.account.id} live=#{finding.live} " \
        "stream=#{finding.from_stream} diff=#{format('%+d', finding.difference)}"
      )
    end
    return if mismatches.size <= MAX_NAMED

    Rails.logger.error(
      "[seat_stream]   named #{MAX_NAMED} of #{mismatches.size} mismatches, rest omitted"
    )
  end

  def log_failures(failed)
    failed.first(MAX_NAMED).each do |finding|
      Rails.logger.error(
        "[seat_stream]   error account=#{finding.account.id} #{finding.error}"
      )
    end
  end

  def log_unopened(unopened)
    return if unopened.empty?

    Rails.logger.warn(
      "[seat_stream]   #{unopened.size} account(s) without an opening, " \
      'run rake seat_events:backfill_openings'
    )
  end
end
