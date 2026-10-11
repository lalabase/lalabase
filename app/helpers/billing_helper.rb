# frozen_string_literal: true

# Option lists for the billing form (doc/billing_stammdaten_plan.md §9). They
# live here rather than in the view because both of them are derived data --
# from the countries gem and from Accounts::BillingRules -- and neither may
# become a second maintenance point next to those two sources.
module BillingHelper
  # The form control styling of the billing form, in one place: the same look is
  # needed by the text rows, the country select and the subdivision select, and
  # a fourth hand-copied variant is how a form starts looking assembled from
  # parts.
  INPUT_CLASSES = 'w-full h-10 px-4 rounded border border-cream-300 focus:outline-none ' \
                  'focus:border-ink focus:ring-1 focus:ring-ink transition-all bg-surface-raised'

  def billing_input_classes
    INPUT_CLASSES
  end

  # Every country, named in the reader's own language, sorted by that name.
  # Sorted AFTER translating, not before: an alphabetical list of English names
  # rendered in German reads as unsorted.
  def billing_country_options
    ISO3166::Country.all
                    .map { |country| [country_label(country), country.alpha2] }
                    .sort_by { |label, _code| collation_key(label) }
  end

  # Subdivisions per country that needs one, as { "US" => [[name, code], ...] }.
  # Only the countries from REGION_REQUIRED_COUNTRIES: the field is not offered
  # anywhere else, and shipping all ~200 subdivision tables into a data
  # attribute would put a few hundred kilobytes into a form nobody asked for.
  #
  # Falls back to #name because the gem carries no subdivision translations for
  # the countries in that list -- checked, not assumed.
  # Memoised because the edit form asks twice: once for the `data-*` payload of
  # the Stimulus controller and once for the server-rendered select of the
  # CURRENT country.
  def billing_subdivision_options
    @billing_subdivision_options ||=
      Accounts::BillingRules::REGION_REQUIRED_COUNTRIES.index_with do |code|
        subdivisions = ISO3166::Country.new(code)&.subdivisions || {}
        subdivisions.map { |sub_code, subdivision| [subdivision.name, sub_code] }
                    .sort_by { |label, _code| collation_key(label) }
      end
  end

  private

  # Falls back to the English short name so an unknown locale renders a country
  # rather than a blank line in the select.
  def country_label(country)
    country.translations[I18n.locale.to_s].presence || country.iso_short_name
  end

  # Sorts by the BASE letter, not by the code point. Plain String#<=> compares
  # bytes, which parks every accented name behind "Z": in the German list that
  # puts Österreich dead last of 249 entries, below Zypern -- the one country
  # after Germany a DACH customer is most likely to look for. Same effect on the
  # Brazilian and Mexican subdivisions (São Paulo after Sergipe, Yucatán after
  # Veracruz).
  #
  # NFD splits "Ö" into "O" + combining diaeresis, and dropping the marks (\p{Mn})
  # leaves "Osterreich" as the sort key -- DIN 5007-1, which is how a German
  # reader scans the list. Non-Latin scripts carry no such base letter and keep
  # their present position at the end rather than being folded into "?".
  #
  # The original label is the tie-breaker, so names that differ only by their
  # accents keep a stable order instead of one shadowing the other.
  def collation_key(label)
    [label.unicode_normalize(:nfd).gsub(/\p{Mn}/, ''), label]
  end
end
