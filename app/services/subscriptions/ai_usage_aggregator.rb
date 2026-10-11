# frozen_string_literal: true

# Writes AiUsageRollup rows: one month of quota-relevant AI consumption per
# organisation, booked onto the Account that bundles it (T17,
# doc/billing_agentur_konto_plan.md §17.3b).
#
# Two entry points, ONE aggregation core -- so a monthly run and a
# deletion-time flush can never compute a month differently:
#
#   .call(period_start:)          monthly job; CLOSED months only
#   .flush_for(organisation:)     before_destroy; every month that still has
#                                 source rows, including the running one
#
# WRITE-ONCE (the property everything else leans on). Both paths insert with
# ON CONFLICT DO NOTHING, so a re-run can only fill gaps. Three failure modes
# collapse into that one rule:
#
#   * The flush writes the running month for a dying org; the monthly job for
#     that same month runs weeks later, finds no source rows (they died with
#     the org) and must not write a 0 over it. It cannot -- there is nothing
#     to write, AND the insert could not overwrite anyway.
#   * `quota_counted` INNER JOINs ai_credentials. A credential that is later
#     deleted (dependent: :nullify) or flipped to included_in_quota: false
#     drops its rows out of the scope; a re-run would otherwise write SMALLER
#     numbers over a settled period.
#
# The unique key is (organisation_id, period_start) and deliberately does NOT
# include account_id: a rollup states a fact about an org and a month, the
# Account is only where it gets booked. With account_id in the key, an org moved
# between Accounts would insert a SECOND row for a period that already exists
# (review finding F2).
#
# Correcting a period is therefore a deliberate, logged act:
# `rake ai_usage_rollups:rebuild`.
#
# The month boundary is NOT defined here: `AiUsage.in_month` owns it, and
# Lalabase::Llm::QuotaLedger#used -- the gate the customer's quota bar shows --
# reads the same scope. A second, local definition would let the invoice drift
# away from the bar without anything turning red.
module Subscriptions
  class AiUsageAggregator
    Result = Struct.new(:inserted, :skipped_without_account, keyword_init: true)

    class MissingAccountError < StandardError; end

    # The one question every failure mode of this service asks: IS THERE A NEXT
    # RUN? :warn means yes (monthly job -- isolate the failure, the next run
    # fills the gap), :raise means no (flush -- the source rows are about to be
    # destroyed). It used to be two parameters, always set to the same value at
    # both call sites; two switches for one question is how the third failure
    # mode gets its own third switch and someone sets it half-way.
    FAILURE_MODES = %i[warn raise].freeze

    class << self
      # Monthly job entry point. CLOSED periods only, see .closed_period?.
      def call(period_start:)
        period = period_start.to_date.beginning_of_month
        raise ArgumentError, open_period_message(period) unless closed_period?(period)

        new.aggregate(period_start: period, on_failure: :warn)
      end

      # A period is rollable once it has ENDED. Rows are write-once, so a row
      # written for a running month would freeze a partial value permanently.
      # Public because `rake ai_usage_rollups:rebuild` must ask the same
      # question BEFORE it deletes anything -- the rule lives here, not twice.
      def closed_period?(period_start)
        period_start.to_date.beginning_of_month < Time.current.to_date.beginning_of_month
      end

      def open_period_message(period)
        "refusing to roll up the open period #{period}: rows are write-once, " \
          'a partial value would be permanent'
      end

      # Deletion-time flush. Runs INSIDE the destroy transaction (prepended
      # before_destroy) and deliberately without a rescue: if it fails, the
      # deletion rolls back. Losing the organisation is recoverable, losing its
      # consumption history is not.
      def flush_for(organisation:)
        new.flush(organisation: organisation)
      end

      # Gap watcher (plan §17.3, point 4). Answers "which closed period has
      # source rows but no rollup row" -- a monthly run that never happened is
      # otherwise invisible until someone reads an invoice.
      def missing_periods(months: 6)
        new.missing_periods(months: months)
      end
    end

    # on_failure (see FAILURE_MODES) separates the two callers: the monthly job
    # can afford to isolate a failure, the flush cannot. It defaults to :raise
    # -- fail closed. Every caller that CAN tolerate a swallowed failure says so
    # explicitly; one that forgets inherits the safe branch, not the quiet one.
    def aggregate(period_start:, organisation: nil, partial: false, on_failure: :raise)
      validate_failure_mode!(on_failure)

      rows = source_rows(period_start: period_start, organisation: organisation)
      return Result.new(inserted: 0, skipped_without_account: 0) if rows.empty?

      records, skipped = build_records(rows, period_start: period_start, partial: partial,
                                             known_organisation: organisation, on_failure: on_failure)
      Result.new(inserted: insert_grouped_by_account(records, on_failure: on_failure),
                 skipped_without_account: skipped)
    end

    def flush(organisation:)
      # The plan says "last rollup -> now", but the honest bound is "everything
      # that still has source rows": a deletion between month end and the
      # monthly run, or after a run that never happened, would otherwise take a
      # WHOLE settled month with it. Before the first backfill that is the
      # entire history of the organisation.
      periods = periods_with_usage(organisation)
      return Result.new(inserted: 0, skipped_without_account: 0) if periods.empty?

      current_period = Time.current.to_date.beginning_of_month
      inserted = periods.sum(0) { |period| flush_period(organisation, period, current_period) }

      Result.new(inserted: inserted, skipped_without_account: 0)
    end

    def missing_periods(months: 6)
      current_period = Time.current.to_date.beginning_of_month
      closed_periods = (1..months).map { |ago| current_period - ago.months }

      closed_periods.flat_map do |period|
        existing = ::AiUsageRollup.for_period(period).pluck(:organisation_id).to_set
        source_rows(period_start: period)
          .map { |row| row[:organisation_id] }
          .reject { |org_id| existing.include?(org_id) }
          .map { |org_id| { period_start: period, organisation_id: org_id } }
      end
    end

    private

    # One month of the flush. Extracted so the bounded per-month loop has a
    # frame of its own in the Prosopite allowlist -- suppressing the whole file
    # would also hide a real N+1 introduced here later.
    def flush_period(organisation, period, current_period)
      aggregate(period_start: period, organisation: organisation,
                partial: period == current_period,
                on_failure: :raise).inserted
    end

    # The single definition of "this month's quota-relevant consumption".
    # AiUsage carries no acts_as_tenant, so this is a plain global query; the
    # scope's INNER JOIN on ai_credentials drops BYOK rows by construction.
    def source_rows(period_start:, organisation: nil)
      scope = ::AiUsage.quota_counted.in_month(period_start.to_date.in_time_zone)
      scope = scope.where(organisation_id: organisation.id) if organisation

      scope.group(:organisation_id)
           .pluck(:organisation_id,
                  Arel.sql('SUM(credits_used)'),
                  Arel.sql('SUM(tokens_used)'),
                  Arel.sql('SUM(cost_cents)'))
           .map do |organisation_id, credits, tokens, cost|
             { organisation_id: organisation_id, credits_used: credits.to_i,
               tokens_used: tokens.to_i, cost_cents: cost.to_d }
           end
    end

    # Every month this organisation has quota-relevant rows in. Derived from
    # min/max and then walked month by month, so the month boundary stays with
    # AiUsage.in_month instead of being restated as SQL here.
    def periods_with_usage(organisation)
      first_used, last_used = ::AiUsage.quota_counted
                                       .where(organisation_id: organisation.id)
                                       .pick(Arel.sql('MIN(used_at)'), Arel.sql('MAX(used_at)'))
      return [] if first_used.blank?

      period = first_used.in_time_zone.to_date.beginning_of_month
      last_period = last_used.in_time_zone.to_date.beginning_of_month
      [].tap do |periods|
        while period <= last_period
          periods << period
          period = period.next_month
        end
      end
    end

    def build_records(rows, period_start:, partial:, known_organisation:, on_failure:)
      organisations = resolve_organisations(rows, known_organisation)
      now = Time.current
      skipped = 0

      records = rows.filter_map do |row|
        organisation = organisations[row[:organisation_id]]
        next record_for(row, organisation, period_start, partial, now) if organisation&.account_id.present?

        skipped += 1
        report_missing_account(row[:organisation_id], period_start, on_failure)
        nil
      end

      [records, skipped]
    end

    # The flush already holds its organisation -- re-reading it once per month
    # would be a query per period for no new information.
    def resolve_organisations(rows, known_organisation)
      return { known_organisation.id => known_organisation } if known_organisation

      ::Organisation.where(id: rows.map { |row| row[:organisation_id] }).index_by(&:id)
    end

    def record_for(row, organisation, period_start, partial, now)
      { account_id: organisation.account_id,
        organisation_id: organisation.id,
        organisation_name: organisation.name,
        period_start: period_start,
        credits_used: row[:credits_used],
        tokens_used: row[:tokens_used],
        cost_cents: row[:cost_cents],
        partial: partial,
        aggregated_at: now,
        created_at: now,
        updated_at: now }
    end

    # An organisation without an Account has nowhere to book its consumption.
    # In a monthly run that is recoverable -- `rake accounts:backfill` and the
    # next run fills the gap, because write-once only blocks rows that already
    # exist. In a flush it is the LAST chance, so it raises and takes the
    # deletion down with it.
    def report_missing_account(organisation_id, period_start, on_failure)
      message = "AiUsageRollup: organisation #{organisation_id} has no account, " \
                "period #{period_start} not booked"
      # Fail closed: only an explicit :warn swallows. Comparing against :raise
      # instead would turn every typo -- and every future third mode -- into
      # silent data loss on the path that is the last chance for these numbers.
      raise MissingAccountError, message unless on_failure == :warn

      Rails.logger.warn(message)
    end

    # An unknown mode must never resolve to "swallow" by accident.
    def validate_failure_mode!(on_failure)
      return if FAILURE_MODES.include?(on_failure)

      raise ArgumentError, "on_failure must be one of #{FAILURE_MODES.inspect}, got #{on_failure.inspect}"
    end

    # Errors are isolated PER ACCOUNT (plan §17.3): one broken account must not
    # cost every other account its month. The aggregation itself stays a single
    # query -- only the write is chunked.
    def insert_grouped_by_account(records, on_failure:)
      records.group_by { |record| record[:account_id] }.sum(0) do |account_id, account_records|
        insert_for_account(account_id, account_records, on_failure: on_failure)
      end
    end

    # The rescue exists for the monthly job only. In the flush it would be
    # exactly the trade AiUsageRollupFlushable rules out: swallow the write
    # error, let the deletion complete, lose the only copy. Postgres usually
    # covers for it (a failed statement poisons the transaction and the cascade
    # dies anyway), but that is a side effect of the driver, not a guarantee --
    # and it does nothing for an error raised before the statement is sent.
    # StandardError, not ActiveRecordError: "isolated per account" has to mean
    # any failure of that account's write, otherwise a RangeError or a nil in
    # the record hash still costs every OTHER account its month -- which is the
    # exact opposite of what the isolation is for. The gap watcher reports what
    # was swallowed, so nothing goes quiet.
    def insert_for_account(account_id, account_records, on_failure:)
      result = ::AiUsageRollup.insert_all(
        account_records, unique_by: :idx_ai_usage_rollups_unique_period
      )
      result.rows.size
    rescue StandardError => e
      raise unless on_failure == :warn

      Rails.logger.error("AiUsageRollup: account #{account_id} failed: #{e.class}: #{e.message}")
      0
    end
  end
end
