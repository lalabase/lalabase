# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::CsvSafe do
  describe '.cell' do
    ['=1+1', '+1', '-1', '@SUM(A1)', "\t=1", "\r=1"].each do |value|
      it "turns #{value.inspect} into text" do
        expect(described_class.cell(value)).to eq("'#{value}")
      end
    end

    it 'leaves ordinary text alone, even with a trigger inside it' do
      expect(described_class.cell('Acme = Co')).to eq('Acme = Co')
    end

    it 'leaves non-strings alone, a negative number included' do
      expect(described_class.cell(-5)).to eq(-5)
      expect(described_class.cell(nil)).to be_nil
    end
  end

  it '.row applies the rule to every cell' do
    expect(described_class.row(['=x', 'ok', 3])).to eq(["'=x", 'ok', 3])
  end
end
