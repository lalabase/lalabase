# frozen_string_literal: true

module Lalabase
  module Llm
    # Computes an organisation's monthly credit consumption against its budget +
    # grace buffer. THE single source for the gate decision (Lalabase::Llm::Gate)
    # AND the consumption UI (bar / banners / Nachweis-Historie) — so what the
    # user sees and what the gate enforces can never disagree.
    #
    # Soft limit (plan §4.3, decision 4A): the gate checks BEFORE a call and books
    # AFTER it, so `used` is the consumption *so far*. A new call is blocked only
    # once `used` has reached the hard limit (budget + buffer); a running answer is
    # never aborted, and a call that tips the org into the grace zone is allowed.
    #
    #   used < budget            → :within   (normal)
    #   budget <= used < hard    → :grace    (allowed + "Kulanz"-Banner)
    #   used >= hard             → :exhausted (gate raises QuotaExceededError)
    #
    # Effective budget/buffer resolve per-org override > SystemSetting default. A
    # 0 override is a valid hard cap (kept distinct from nil = "use default").
    class QuotaLedger
      attr_reader :organisation

      def self.for(organisation, now: Time.current)
        new(organisation, now: now)
      end

      def initialize(organisation, now: Time.current)
        @organisation = organisation
        @now = now
      end

      # Memoised for the same reason #used is: a ledger is asked SEVERAL times per
      # render — the quota bar and the AI hub card each ask budget, hard_exhausted?,
      # in_grace? and usage_percent, and the last three resolve through budget/buffer
      # again. Unmemoised that is one SystemSetting.get per question, and
      # SystemSetting.get is an uncached find_by in every environment: the AI hub paid
      # EIGHT of them for one card (measured). Nothing here changes within a request —
      # a per-org override is a column on a loaded row, the fallback an operator setting.
      #
      # `defined?` rather than `||=`: both values may legitimately be 0 (a hard-cap org
      # has budget 0), and `||=` would re-query on every call for exactly those orgs —
      # the ones already sitting at their limit.
      def budget
        return @budget if defined?(@budget)

        override = @organisation.ai_quota_credits_override
        @budget = override.nil? ? SystemSetting.ai_quota_monthly_credits : [override.to_i, 0].max
      end

      def buffer
        return @buffer if defined?(@buffer)

        override = @organisation.ai_quota_buffer_override
        @buffer = override.nil? ? SystemSetting.ai_quota_grace_buffer_credits : [override.to_i, 0].max
      end

      def hard_limit
        budget + buffer
      end

      # Credits consumed this calendar month by quota-counted calls (system
      # credential with included_in_quota; BYOK naturally excluded via the scope's
      # inner join). Memoised — the gate reads it once per resolution.
      def used
        @used ||= @organisation.ai_usages.quota_counted.in_month(@now).sum(:credits_used)
      end

      def remaining
        [budget - used, 0].max
      end

      def within_budget?
        used < budget
      end

      def in_grace?
        used >= budget && used < hard_limit
      end

      # The gate's decision point: block a NEW call once the hard limit is reached.
      def hard_exhausted?
        used >= hard_limit
      end

      # Percentage of the *budget* consumed (can exceed 100 in the grace zone).
      # A zero-budget (hard-cap) org has no ratio: 0% while unused, but 100% once
      # anything is spent — otherwise the bar would read "0%" while the org is
      # actually blocked. Also avoids a divide-by-zero.
      def usage_percent
        return used.positive? ? 100 : 0 if budget <= 0

        ((used.to_f / budget) * 100).round
      end

      # :within / :grace / :exhausted — feeds the central UI state helper.
      def state
        return :exhausted if hard_exhausted?
        return :grace if in_grace?

        :within
      end

      # ~6 months of consumption vs. limit for the Nachweis-Historie (org + admin
      # backend). Oldest → newest. The `budget`/`hard_limit` shown is the CURRENT
      # effective limit (historical limits are not stored — a documented v1
      # simplification; it is the reference line the gate would use today).
      #
      # `used` is SUMMED from `by_action`, never fetched separately: total and
      # breakdown are the same numbers by construction, so the drill-down can never
      # contradict the row it hangs under — which is the whole point of a Nachweis.
      #
      # @return [Array<Hash>] { month: Date (first of month), used: Integer,
      #   budget: Integer, hard_limit: Integer,
      #   by_action: Array<{ action: String|nil, credits: Integer, count: Integer }> }
      def history(months: 6)
        # The months we report, oldest → newest (e.g. [Feb, Mar, Apr, May, Jun, Jul]).
        month_starts = (0...months).map { |ago| (@now - ago.months).beginning_of_month.to_date }.reverse
        breakdown_by_month = monthly_used_credits(since: month_starts.first)

        # The CURRENT effective limit is the reference line for every month —
        # historical limits are not stored (documented v1 simplification).
        current_budget = budget
        current_hard = hard_limit
        month_starts.map do |month|
          by_action = breakdown_by_month.fetch(month, [])
          { month: month, used: by_action.sum { |entry| entry[:credits] },
            budget: current_budget, hard_limit: current_hard, by_action: by_action }
        end
      end

      private

      # ONE grouped query (no per-month N+1, no second aggregate query):
      # { first-of-month Date => [{ action:, credits:, count: }, ...] } for every
      # month with usage since `since`, each month's entries sorted by credits desc
      # (ties broken by action, so the order is stable across calls).
      #
      # Buckets by the DB month of used_at — rows within ~1-2h of a month boundary
      # can land in the neighbouring bucket under a non-UTC app tz, an accepted
      # display-only nuance (the gate's `used` stays the exact in_month sum).
      # Months without usage are absent → callers default to an empty breakdown.
      #
      # `action` is nullable by design (nullable-first rollout, see AiUsage), so
      # pre-rollout rows group into an `action: nil` bucket. That bucket MUST be
      # kept: dropping it would make the detail rows fall short of the month total.
      def monthly_used_credits(since:)
        rows = @organisation.ai_usages
                            .quota_counted
                            .where(used_at: since.beginning_of_month..@now.end_of_month)
                            .group(Arel.sql("date_trunc('month', used_at)"), :action)
                            .pluck(Arel.sql("date_trunc('month', used_at)"), :action,
                                   Arel.sql('SUM(credits_used)'), Arel.sql('COUNT(*)'))

        rows.group_by { |timestamp, _action, _credits, _count| timestamp.to_date.beginning_of_month }
            .transform_values { |month_rows| sorted_action_entries(month_rows) }
      end

      # Biggest consumer first — that is the question the drill-down answers.
      def sorted_action_entries(month_rows)
        month_rows
          .map { |_timestamp, action, credits, count| { action: action, credits: credits.to_i, count: count.to_i } }
          .sort_by { |entry| [-entry[:credits], entry[:action].to_s] }
      end
    end
  end
end
