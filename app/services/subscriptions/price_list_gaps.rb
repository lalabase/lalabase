# frozen_string_literal: true

# Finds dates from today onwards on which NO price level would apply
# (doc/billing_preisliste_rabatt_plan.md D2, review finding M1).
#
# Why this exists at all: a check for "does a price apply today" cannot see a
# gap that opens next month. That is precisely how the dangerous case looks --
# an announcement gets withdrawn or moved, the predecessor stays clipped, and
# nothing is wrong until the day arrives, at which point the public price API
# answers with an empty payload and the website shows no amount. This turns
# that silent state into something the admin banner and the deploy check can
# both read.
#
# Callers are in the operator engine only (gboyke/lalabase-operator, S3.2): the
# price list page and `rake subscription_prices:check`. The rule stays in the
# core, next to the model it reads.
#
# Entry point: upcoming
module Subscriptions
  class PriceListGaps
    class << self
      # Returns [{ from: Date, to: Date or nil }], empty when coverage is
      # seamless. `to: nil` means the gap never closes -- no open-ended level
      # follows.
      def upcoming(plan_key: Constants::PLAN_CLOUD, from: Date.current)
        gaps_in(relevant_lists(plan_key, from), from)
      end

      # The same answer for every plan, as { plan_key => gaps }, from one query.
      # A plan that never had a level has one open gap from `from` on: a plan
      # nobody can be priced on is exactly what the warning is for.
      def upcoming_by_plan(from: Date.current)
        by_plan = relevant_lists(Constants::PLAN_KEYS, from).group_by(&:plan_key)
        Constants::PLAN_KEYS.index_with { |plan_key| gaps_in(by_plan.fetch(plan_key, []), from) }
      end

      private

      # `price_lists` ordered by start, all of one plan.
      def gaps_in(price_lists, from)
        gaps = []
        cursor = from

        price_lists.each do |price_list|
          gaps << { from: cursor, to: price_list.starts_on - 1.day } if price_list.starts_on > cursor
          # An open-ended level covers everything after it -- nothing left to check.
          return gaps if price_list.ends_on.nil?

          cursor = price_list.ends_on + 1.day if price_list.ends_on >= cursor
        end

        gaps << { from: cursor, to: nil }
        gaps
      end

      # Levels that already ended are irrelevant: they cannot cover a future
      # date and would only shift the cursor backwards. `plan_key` may be one
      # key or several.
      def relevant_lists(plan_key, from)
        PriceList.for_plan(plan_key)
                 .where(ends_on: from..).or(PriceList.for_plan(plan_key).where(ends_on: nil))
                 .order(:starts_on)
      end
    end
  end
end
