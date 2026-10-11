# frozen_string_literal: true

require 'rails_helper'

# The one place stored cents become text (doc/billing_preisliste_rabatt_plan.md
# §7). The locale half matters as much as the rounding half: until 2026-08 the
# German tree had no `number` key, rails-i18n is not bundled, and every German
# amount silently fell back to the English Rails default -- "€14.50" on a German
# page. These examples pin both locales so removing `de.number` fails here
# rather than on a customer's screen.
RSpec.describe PriceHelper do
  describe '#format_price_cents' do
    context 'in German' do
      around { |example| I18n.with_locale(:de) { example.run } }

      it 'puts the unit last and uses a comma as the decimal separator' do
        expect(helper.format_price_cents(1450)).to eq('14,50 €')
      end

      it 'drops the decimals on round amounts' do
        expect(helper.format_price_cents(2900)).to eq('29 €')
      end

      it 'groups thousands with a dot' do
        expect(helper.format_price_cents(120_000)).to eq('1.200 €')
      end
    end

    context 'in English' do
      around { |example| I18n.with_locale(:en) { example.run } }

      it 'puts the unit first and uses a dot as the decimal separator' do
        expect(helper.format_price_cents(1450)).to eq('€14.50')
      end

      it 'groups thousands with a comma' do
        expect(helper.format_price_cents(120_000)).to eq('€1,200')
      end
    end

    it 'returns nil for a missing amount rather than a zero price' do
      expect(helper.format_price_cents(nil)).to be_nil
    end

    # The currency comes from the row, not from a hardcoded sign -- otherwise the
    # `currency` column is dead decoration.
    it 'honours a non-default currency' do
      I18n.with_locale(:de) do
        expect(helper.format_price_cents(2900, 'CHF')).to eq('29 CHF')
      end
    end
  end

  describe '#format_monthly_equivalent' do
    around { |example| I18n.with_locale(:de) { example.run } }

    it 'divides a yearly amount by the months from the registry' do
      expect(helper.format_monthly_equivalent(27_840, 'yearly')).to eq('23,20 €')
    end

    it 'leaves a monthly amount untouched' do
      expect(helper.format_monthly_equivalent(2900, 'monthly')).to eq('29 €')
    end

    it 'raises on an unknown interval rather than assuming one month' do
      expect { helper.format_monthly_equivalent(2900, 'weekly') }.to raise_error(ArgumentError)
    end
  end
end
