# frozen_string_literal: true

# Renders a cent amount exactly the way the app does, for specs that need to find an
# amount in a rendered page.
#
# Exists because the obvious needle does not work here. `format_price_cents` drops the
# decimals on round amounts ("29 €", never "29,00 €"), so a needle like '29,00' occurs
# nowhere in this application and an expectation against it can never fail. The other
# direction is worse: the bare digits '29' appear about seventy times on every page,
# because the importmap puts asset digest hashes there -- an `include('29')` is true by
# construction, on a page showing no amount at all (measured 2026-08-06).
#
# The currency symbol is what makes the difference: it only ever appears where an amount
# was actually rendered.
module PriceFormatting
  def formatted_price(cents, currency = Subscriptions::Constants::DEFAULT_CURRENCY)
    price_formatter.format_price_cents(cents, currency)
  end

  # PriceHelper is a view helper and needs number_to_currency from ActionView; this is the
  # smallest object that supplies it. Deliberately the REAL helper rather than a
  # reimplementation: an expectation built from a second formatter would keep passing
  # while the page renders euros in the English format, which is exactly the defect the
  # helper exists to prevent.
  def price_formatter
    @price_formatter ||= Class.new do
      include ActionView::Helpers::NumberHelper
      include PriceHelper
    end.new
  end
end

RSpec.configure do |config|
  config.include PriceFormatting, type: :request
end
