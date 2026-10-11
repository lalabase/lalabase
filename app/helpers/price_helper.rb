# frozen_string_literal: true

# Formatting for stored cent amounts (doc/billing_preisliste_rabatt_plan.md §7).
# One place, not three: the same rule is needed on the public pricing page, in
# the admin ladder and in the amount preview.
module PriceHelper
  # Renders cents as currency, dropping the decimals on round amounts ("29 €"
  # rather than "29,00 €") and keeping them otherwise. The unit sits BEFORE or
  # AFTER the number depending on locale, and the separator with it: the German
  # page reads "14,50 €", the English one "€14.50".
  #
  # That split comes from `number.currency.format` in the locale files, NOT from
  # rails-i18n — the gem is not bundled here. Until 2026-08 the German tree had
  # no `number` key at all, so every amount silently fell back to the English
  # Rails default and the German UI rendered "€14.50". Deleting `de.number`
  # brings that back without failing anything but the pricing-page spec.
  def format_price_cents(cents, currency = Subscriptions::Constants::DEFAULT_CURRENCY)
    return nil if cents.nil?

    precision = (cents % 100).zero? ? 0 : 2
    number_to_currency(cents / 100.0, unit: currency_unit(currency), precision: precision)
  end

  # The monthly equivalent of a period amount -- divided by the interval's
  # months from the registry, never by a hardcoded 12 (D10).
  def format_monthly_equivalent(cents, billing_interval,
                                currency = Subscriptions::Constants::DEFAULT_CURRENCY)
    return nil if cents.nil?

    months = Subscriptions::Constants.months_for(billing_interval)
    format_price_cents((cents.to_f / months).round, currency)
  end

  private

  def currency_unit(currency)
    currency.to_s == Subscriptions::Constants::DEFAULT_CURRENCY ? '€' : currency.to_s
  end
end
