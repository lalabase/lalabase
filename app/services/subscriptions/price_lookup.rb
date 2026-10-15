# frozen_string_literal: true

# Resolves WHICH price applies (doc/billing_preisliste_rabatt_plan.md §5).
# The single place in the app where a validity date or a seat range is
# compared -- neither views nor controllers query dates or rungs themselves, so
# the inclusive-end semantics (D2) exist exactly once.
#
# Two questions, two methods: `.current` answers "which price level applies on
# this date", `.tier_for` additionally answers "which rung does this seat count
# fall on".
#
# Entry point: current
module Subscriptions
  class PriceLookup
    class << self
      # The price level in force on `on`, or nil. Deliberately nil and not an
      # exception: a missing price level is an operational state the public
      # pricing page has to survive (D7), not a programming error.
      def current(plan_key: Constants::PLAN_CLOUD, on: Date.current)
        PriceList.for_plan(plan_key)
                 .effective_on(on)
                 # The no-overlap rule guarantees at most one match; ordering
                 # makes the outcome deterministic anyway, so a violated
                 # invariant degrades to "the most recent one wins" instead of
                 # to a random row.
                 .order(starts_on: :desc)
                 .first
      end

      # The level in force on `on` for every plan that has one, as
      # { plan_key => PriceList }, in one query. For the callers that need
      # several plans at once (the account list, the public price lists); one
      # `.current` per plan would be an N+1 over the plan registry.
      def current_by_plan(on: Date.current)
        PriceList.where(plan_key: Constants::PLAN_KEYS)
                 .effective_on(on)
                 .includes(:tiers)
                 # Same tie-break as .current: the most recent start wins.
                 .order(starts_on: :desc)
                 .group_by(&:plan_key)
                 .transform_values(&:first)
      end

      # The rung for `seats`, or nil when no price level applies or no rung
      # covers that seat count.
      def tier_for(seats:, billing_interval: Constants::INTERVAL_MONTHLY,
                   plan_key: Constants::PLAN_CLOUD, on: Date.current)
        price_list = current(plan_key: plan_key, on: on)
        return nil if price_list.nil?

        tier_in(price_list, seats: seats, billing_interval: billing_interval)
      end

      # Same resolution against an ALREADY loaded price level, for callers that
      # hold the list and would otherwise pay for a second query. Used by
      # .tier_for; the pricing page (P5) is its second caller.
      #
      # A seat count below the first rung yields nil rather than silently
      # falling back to the cheapest rung: "zero seats" is a question about an
      # account without a paid member, and answering it with a price would be a
      # wrong answer, not a missing one.
      def tier_in(price_list, seats:, billing_interval: Constants::INTERVAL_MONTHLY)
        return nil if seats.nil? || seats < 1

        price_list.tiers
                  .select { |tier| tier.billing_interval == billing_interval }
                  .detect { |tier| tier.covers?(seats) }
      end
    end
  end
end
