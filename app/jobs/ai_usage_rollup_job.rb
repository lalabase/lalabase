# frozen_string_literal: true

# Monthly AI-consumption rollup (T17, doc/billing_agentur_konto_plan.md §17.3b,
# registered in config/recurring.yml). Aggregates the month that just CLOSED
# onto each Account, so the numbers survive the deletion of the organisation
# that produced them.
#
# Two properties worth knowing before changing anything here:
#
#   * It rolls up the PREVIOUS month, never the running one. Rollup rows are
#     write-once (see Subscriptions::AiUsageAggregator), so a row written for an
#     open month would freeze a partial value permanently. The running month is
#     served live by Lalabase::Llm::QuotaLedger.
#   * A missed run is harmless and self-healing: `catch_up_months` re-checks the
#     recent past every time, and write-once means an already-settled period is
#     skipped rather than rewritten. What is NOT self-healing is a month whose
#     organisation was deleted in the meantime -- that one is covered by the
#     deletion flush, not by this job.
#
# The gap check logs what neither mechanism caught. Without it a scheduler that
# quietly stopped running would surface for the first time on an invoice.
class AiUsageRollupJob < ApplicationJob
  queue_as :default

  # How far back each run re-checks for unwritten periods. Six months is the
  # same window Lalabase::Llm::QuotaLedger#history shows the customer.
  CATCH_UP_MONTHS = 6

  def perform(catch_up_months: CATCH_UP_MONTHS)
    current_period = Time.current.to_date.beginning_of_month

    (1..catch_up_months).each do |months_ago|
      roll_up(current_period - months_ago.months)
    end

    report_gaps(catch_up_months)
  end

  private

  def roll_up(period_start)
    result = Subscriptions::AiUsageAggregator.call(period_start: period_start)
    return if result.inserted.zero? && result.skipped_without_account.zero?

    Rails.logger.info(
      "AiUsageRollupJob: #{period_start} -> #{result.inserted} rollups written, " \
      "#{result.skipped_without_account} organisations skipped (no account)"
    )
  end

  def report_gaps(catch_up_months)
    gaps = Subscriptions::AiUsageAggregator.missing_periods(months: catch_up_months)
    return if gaps.empty?

    # Reaching this point means a period has source rows but no rollup row and
    # the write above did not fix it. Two causes: the organisation has no
    # Account (remedy `rake accounts:backfill`), or its insert failed and was
    # isolated -- in which case the per-account error is in the log right above
    # this line.
    Rails.logger.error(
      "AiUsageRollupJob: #{gaps.size} period(s) still without a rollup: " \
      "#{gaps.map { |gap| "#{gap[:period_start]}/#{gap[:organisation_id]}" }.join(', ')}"
    )
  end
end
