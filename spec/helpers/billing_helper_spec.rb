# frozen_string_literal: true

require 'rails_helper'

# What: the option lists of the billing form (B3, doc/billing_stammdaten_plan.md §9).
# Type: helper spec.
# Why:  Both lists are DERIVED -- from the countries gem and from
#       Accounts::BillingRules -- and a wrong derivation fails quietly: the form still
#       renders, it just offers the wrong things. The two properties worth pinning are
#       that the country names follow the reader's locale (a German list sorted by
#       English names looks broken) and that the subdivision map covers exactly the
#       countries the region field is offered for.
RSpec.describe BillingHelper, type: :helper do
  describe '#billing_country_options' do
    it 'names the countries in the current locale' do
      I18n.with_locale(:de) do
        expect(helper.billing_country_options).to include(%w[Deutschland DE])
      end

      I18n.with_locale(:en) do
        expect(helper.billing_country_options).to include(%w[Germany DE])
      end
    end

    # Sorting BEFORE translating would order by the English name and render a list that
    # looks shuffled to a German reader.
    it 'sorts by the translated name, not by the code' do
      I18n.with_locale(:de) do
        names = helper.billing_country_options.map(&:first)

        expect(names.index('Deutschland')).to be < names.index('Frankreich')
        expect(names.index('Frankreich')).to be < names.index('Italien')
      end
    end

    # Deliberately NOT `expect(names).to eq(names.sort)`: that compares the helper's output
    # against the SAME String#<=> the helper sorted with, so it is true by construction and
    # stays green while every umlaut name sits behind Zypern. Byte order puts Österreich at
    # index 248 of 249 -- past the end of the list a DACH customer scrolls.
    it 'sorts umlaut names by their base letter instead of parking them behind Z' do
      I18n.with_locale(:de) do
        names = helper.billing_country_options.map(&:first)
        umlaut_names = names.grep(/\A[ÄÖÜÅ]/)

        expect(umlaut_names).to include('Österreich')
        expect(umlaut_names.map { |name| names.index(name) })
          .to all(be < names.index('Zypern'))
      end
    end
  end

  describe '#billing_subdivision_options' do
    # Exactly the countries whose tax treatment needs a subdivision -- no more, because the
    # ~200 remaining subdivision tables would travel into a data attribute for nothing.
    it 'covers exactly the region-required countries' do
      expect(helper.billing_subdivision_options.keys)
        .to match_array(Accounts::BillingRules::REGION_REQUIRED_COUNTRIES)
    end

    it 'lists the subdivisions of a country by name, sorted' do
      states = helper.billing_subdivision_options.fetch('US').map(&:first)

      expect(helper.billing_subdivision_options.fetch('US')).to include(%w[Alaska AK])
      expect(states.index('Alabama')).to be < states.index('Wyoming')
    end

    # The same byte-order trap as the country list, and the reason the US table alone does
    # not catch it: US subdivision names are pure ASCII, so any comparator looks correct
    # there. Brazil and Mexico are where accented names would fall out of the list.
    it 'sorts accented subdivision names by their base letter' do
      states = helper.billing_subdivision_options.fetch('BR').map(&:first)
      estados = helper.billing_subdivision_options.fetch('MX').map(&:first)

      expect(states.index('São Paulo')).to be < states.index('Sergipe')
      expect(estados.index('Yucatán')).to be < estados.index('Zacatecas')
    end

    # Every entry must carry a usable label. The gem has no subdivision TRANSLATIONS for
    # these countries, so the fallback to #name is the load-bearing part -- without it the
    # select would render a column of blank options.
    it 'never produces a blank label' do
      labels = helper.billing_subdivision_options.values.flatten(1).map(&:first)

      expect(labels).to all(be_present)
    end
  end
end
