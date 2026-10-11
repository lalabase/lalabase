# frozen_string_literal: true

module Accounts
  # The country-dependent rules of the billing master data, in ONE place
  # (doc/billing_stammdaten_plan.md E5). Server validation, the later Strong
  # Parameters whitelist and the Stimulus field behaviour all read from here --
  # the field list must never be maintained in three places.
  module BillingRules
    # Required in the :billing context (E3). Also drives #billing_complete? and
    # the all-or-nothing "may be cleared entirely, may not be half-filled" rule.
    # billing_region and vat_id are NOT here: both are conditionally required
    # and have their own validator.
    REQUIRED_FIELDS = %i[
      billing_name
      billing_street
      billing_postal_code
      billing_city
      billing_country
      billing_email
    ].freeze

    OPTIONAL_FIELDS = %i[
      billing_addressee
      billing_street_2
      billing_region
      billing_email_cc
      billing_reference
      vat_id
    ].freeze

    # What a customer may ever submit. The verification and confirmation columns
    # (vat_id_status, vat_id_checked_*, business_confirmed_*) are set by the
    # system only and are deliberately absent -- otherwise a customer could put
    # themselves on "VAT ID verified".
    PERMITTED_FIELDS = (REQUIRED_FIELDS + OPTIONAL_FIELDS).freeze

    # Countries whose tax treatment needs a subdivision (Stripe Tax).
    REGION_REQUIRED_COUNTRIES = %w[US CA AU IN BR MX].freeze

    # The EU VAT area, NOT "EU membership". These two are not the same list, and
    # the difference is not academic: ISO3166::Country#in_eu? answers with 34
    # codes because it counts the French overseas departments (GF, GP, MQ, RE,
    # YT), Saint-Martin and Åland -- all of them EU territory, all of them
    # OUTSIDE the EU VAT area. Deriving this list from the gem would demand a
    # VAT ID from a customer in Guadeloupe who cannot have one. It is also a
    # legal statement (E11), so it belongs in the repository as an auditable
    # list rather than in a dependency's data file.
    EU_VAT_COUNTRIES = %w[
      AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE
      IT LT LU LV MT NL PL PT RO SE SI SK
    ].freeze

    # E11: an EU customer outside Germany must supply a VAT ID, otherwise they
    # are treated like a non-business and local VAT plus OSS registration would
    # apply. German customers pay German VAT and need none.
    VAT_ID_REQUIRED_COUNTRIES = (EU_VAT_COUNTRIES - %w[DE]).freeze

    # Countries the field is offered for at all. Wider than the required list:
    # a Swiss or British business has a VAT number worth putting on the invoice,
    # it is just not mandatory for us.
    VAT_ID_OFFERED_COUNTRIES = (EU_VAT_COUNTRIES + %w[GB CH]).freeze

    # A VAT ID carries its own country in its first two letters, and that prefix
    # is NOT the ISO country code in two cases: Greece is country GR but writes
    # EL, and Northern Ireland writes XI under the GB pattern. valvat keys its
    # pattern table by the ISO code, so this maps a prefix back to that key.
    # Note it is many-to-one: GB and XI share one pattern.
    VAT_PREFIX_TO_PATTERN_KEY = { 'EL' => 'GR', 'XI' => 'GB' }.freeze

    # Exactly what valvat can check offline. For CH, AU, IN or CA it has no
    # patterns and would reject VALID numbers, so those pass through unchecked
    # until Stripe verifies them.
    #
    # Keyed off the PREFIX OF THE ID, never off billing_country. Three reasons,
    # all of which were live gaps before: by country, every Greek customer would
    # be rejected; an ID typed before a country was picked would not be checked
    # at all, which is exactly what the context-free check exists to prevent;
    # and a Northern Irish XI number would slip past unchecked although valvat
    # matches it (its GB pattern is /\A(GB|XI)…/).
    VAT_FORMAT_CHECKED_PREFIXES =
      (EU_VAT_COUNTRIES.map { |code| code == 'GR' ? 'EL' : code } + %w[GB XI]).freeze

    module_function

    def region_required?(country_code)
      REGION_REQUIRED_COUNTRIES.include?(country_code)
    end

    def vat_id_required?(country_code)
      VAT_ID_REQUIRED_COUNTRIES.include?(country_code)
    end

    def vat_id_offered?(country_code)
      VAT_ID_OFFERED_COUNTRIES.include?(country_code)
    end

    # Takes the ID, not a country. See VAT_FORMAT_CHECKED_PREFIXES.
    def vat_format_checkable?(vat_id)
      return false if vat_id.blank?

      VAT_FORMAT_CHECKED_PREFIXES.include?(vat_id[0, 2].to_s.upcase)
    end
  end
end
