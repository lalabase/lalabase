# frozen_string_literal: true

module Api
  module Public
    module V1
      # Returns the price list currently published for the public website.
      class PriceListsController < Api::Public::BaseController
        # Keep publication changes bounded while still making the endpoint CDN-friendly.
        CACHE_TTL = 5.minutes

        def show
          price_list = Subscriptions::PriceLookup.current
          payload = Subscriptions::PublicPriceListPayload.call(price_list: price_list)

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
