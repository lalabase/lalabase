# frozen_string_literal: true

module Accounts
  # The postal part of an Account's billing details as a value object
  # (doc/billing_stammdaten_plan.md E2/§5). It exists rather than a view helper
  # because the same formatting is needed in at least three places: the customer
  # view, the admin view, and the invoice snapshot of the Stripe phase.
  #
  # #to_h is the snapshot seam. An issued invoice must carry the address as a
  # FROZEN COPY, so that a later address change can never rewrite an old
  # invoice. This object produces that copy; it does not decide where it is
  # stored.
  #
  # Country codes are rendered through the countries gem, so the customer reads
  # "Deutschland" and not "DE", in their own locale.
  class BillingAddress
    ADDRESS_FIELDS = %i[
      billing_name billing_addressee billing_street billing_street_2
      billing_postal_code billing_city billing_region billing_country
    ].freeze

    def initialize(account)
      @account = account
    end

    ADDRESS_FIELDS.each do |field|
      # billing_street_2 -> #street_2; the prefix is redundant inside this object.
      define_method(field.to_s.delete_prefix('billing_')) { @account.public_send(field) }
    end

    def present?
      ADDRESS_FIELDS.any? { |field| @account.public_send(field).present? }
    end

    # The country's name in the current locale, falling back to the raw code so
    # an unknown or stale code still renders something instead of blanking the
    # address out.
    def country_name
      return nil if country.blank?

      ISO3166::Country.new(country)&.translations&.[](I18n.locale.to_s) || country
    end

    # Postal order: recipient, care-of, street, "postcode city", region,
    # country. Blank lines are dropped, so a two-line address stays two lines.
    def lines
      [
        name,
        addressee,
        street,
        street_2,
        [postal_code, city].compact_blank.join(' '),
        region,
        country_name
      ].compact_blank
    end

    def to_s
      lines.join(', ')
    end

    # The snapshot. Keys are the column names, not the shortened readers, so a
    # stored copy stays readable next to the table it came from.
    def to_h
      ADDRESS_FIELDS.index_with { |field| @account.public_send(field) }
    end
  end
end
