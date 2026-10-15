# frozen_string_literal: true

module Api
  module Public
    module V1
      # Returns the price lists currently published for the public website.
      #
      # `show` (GET /price_list) is the first contract and answers for the plan
      # 'cloud' only; it stays until the website reads `index`. `index`
      # (GET /price_lists, since 2026-10-15) answers for every plan that has a
      # price level in force, so the website gets both prices from one request
      # and one moment (doc/billing_preisliste_rabatt_plan.md §13).
      class PriceListsController < Api::Public::BaseController
        # Keep publication changes bounded while still making the endpoint CDN-friendly.
        CACHE_TTL = 5.minutes

        def index
          by_plan = Subscriptions::PriceLookup.current_by_plan
          price_lists = Subscriptions::Constants::PLAN_KEYS.filter_map { |plan_key| by_plan[plan_key] }
          render_cached Subscriptions::PublicPriceListPayload.collection(price_lists: price_lists)
        end

        def show
          price_list = Subscriptions::PriceLookup.current
          render_cached Subscriptions::PublicPriceListPayload.call(price_list: price_list)
        end

        private

        def render_cached(payload)
          # Derive the cache identity from the response bytes so a list change cannot reuse an ETag.
          body = ActiveSupport::JSON.encode(payload)

          expires_in CACHE_TTL, public: true
          return unless stale?(etag: Digest::SHA256.hexdigest(body), public: true)

          # Render exactly the bytes hashed above so representation and ETag cannot drift.
          render body: body, content_type: 'application/json'
        end
      end
    end
  end
end
