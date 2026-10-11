# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::MoneyInput do
  describe '.cents' do
    # The regression this class exists for: the previous tr(',', '.') turned
    # "1.234,50" into "1.234.50", BigDecimal stopped at the second separator,
    # and 1234,50 EUR was published as 1,23 EUR -- passing every ladder
    # invariant on the way.
    it 'reads the German thousands dot' do
      expect(described_class.cents('1.234,50')).to eq(123_450)
    end

    it 'reads the English thousands comma' do
      expect(described_class.cents('1,234.50')).to eq(123_450)
    end

    {
      '29' => 2900,
      '29,50' => 2950,
      '29.50' => 2950,
      '29,5' => 2950,
      '0' => 0,
      '100' => 10_000,
      '1.000' => 100_000,
      ' 29,50 € ' => 2950
    }.each do |input, expected|
      it "reads #{input.inspect} as #{expected} cents" do
        expect(described_class.cents(input)).to eq(expected)
      end
    end

    # The mirror image of the thousands-dot bug, and just as expensive: read as
    # English thousands, "2,999" published 2.999,00 EUR where 2,99 was meant.
    # A comma group without a decimal point is genuinely ambiguous in a German
    # UI, so it is refused rather than guessed.
    it 'refuses a bare comma group instead of reading it as English thousands' do
      expect(described_class.cents('2,999')).to be_nil
      expect(described_class.cents('29,999')).to be_nil
      expect(described_class.cents('1,234')).to be_nil
    end

    it 'still reads an English amount that carries its decimal point' do
      expect(described_class.cents('1,234.50')).to eq(123_450)
    end

    it 'leaves the unambiguous forms typeable' do
      expect(described_class.cents('1.234')).to eq(123_400)
      expect(described_class.cents('1234')).to eq(123_400)
      expect(described_class.cents('2,99')).to eq(299)
    end

    # nil, never 0: only that lets the caller tell "left blank" apart from
    # "deliberately zero", which is what makes the ladder validator able to
    # refuse an incomplete form instead of publishing a free product.
    ['', '   ', nil, 'abc', '29,5,0', '-5', '29€50', '1.2345'].each do |input|
      it "refuses #{input.inspect} with nil rather than zero" do
        expect(described_class.cents(input)).to be_nil
      end
    end

    it 'rounds half up on the cent' do
      expect(described_class.cents('0,005')).to be_nil # more than two decimals is not a price
      expect(described_class.cents('12,34')).to eq(1234)
    end
  end
end
