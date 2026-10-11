# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Languages do
  describe 'constants (single source of truth, locked as contract)' do
    it { expect(described_class::SUPPORTED).to contain_exactly('de', 'en') }
    it { expect(described_class::SUPPORTED).to be_frozen }
    it { expect(described_class::DEFAULT).to eq('en') }
    it { expect(described_class::DEFAULT).to be_in(described_class::SUPPORTED) }
  end

  describe '.coerce' do
    it 'passes a supported language through unchanged' do
      expect(described_class.coerce('de')).to eq('de')
      expect(described_class.coerce('en')).to eq('en')
    end

    it 'falls back to DEFAULT for an unsupported language' do
      expect(described_class.coerce('fr')).to eq('en')
    end

    it 'falls back to DEFAULT for nil and empty string' do
      expect(described_class.coerce(nil)).to eq('en')
      expect(described_class.coerce('')).to eq('en')
    end

    it 'coerces a symbol via to_s before checking' do
      expect(described_class.coerce(:de)).to eq('de')
    end
  end
end
