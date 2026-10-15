# frozen_string_literal: true

# Serializes one published price list into the stable public API contract used
# by the website. Internal identifiers, audit fields and validity dates stay out.
# Contract and field semantics: docs/api/public_v1.md.
#
# `call` wraps one list (GET /price_list), `collection` several, one per plan
# (GET /price_lists). Both serialize a list the same way.
module Subscriptions
  class PublicPriceListPayload
    def self.call(**kwargs)
      new(**kwargs).call
    end

    def self.collection(price_lists:)
      { data: { price_lists: price_lists.map { |price_list| new(price_list: price_list).serialized_price_list } } }
    end

    def initialize(price_list:)
      @price_list = price_list
    end

    def call
      { data: { price_list: serialized_price_list } }
    end

    def serialized_price_list
      return nil if @price_list.nil?

      tiers = @price_list.tiers.to_a.select do |tier|
        Constants::BILLING_INTERVAL_KEYS.include?(tier.billing_interval)
      end
      {
        plan: @price_list.plan_key,
        currency: @price_list.currency,
        billing_intervals: billing_intervals(tiers),
        tiers: serialized_tiers(tiers)
      }
    end

    private

    def billing_intervals(tiers)
      published = tiers.map(&:billing_interval).uniq
      Constants::BILLING_INTERVAL_KEYS.filter_map do |key|
        { key: key, months: Constants.months_for(key) } if published.include?(key)
      end
    end

    def serialized_tiers(tiers)
      interval_order = Constants::BILLING_INTERVAL_KEYS.each_with_index.to_h
      tiers.sort_by { |tier| [interval_order.fetch(tier.billing_interval), tier.min_seats] }
           .map { |tier| serialize_tier(tier) }
    end

    def serialize_tier(tier)
      {
        billing_interval: tier.billing_interval,
        min_seats: tier.min_seats,
        max_seats: tier.max_seats,
        base_amount_cents: tier.base_amount_cents,
        per_seat_amount_cents: tier.per_seat_amount_cents
      }
    end
  end
end
