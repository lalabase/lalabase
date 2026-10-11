# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Uuid do
  let(:id) { '0f8fad5b-d9cb-469f-a165-70867728950e' }

  describe '.dashed' do
    it 'brings every spelling valid? lets in to the canonical one' do
      expect(described_class.dashed(id)).to eq(id)
      expect(described_class.dashed(id.upcase)).to eq(id)
      expect(described_class.dashed(id.delete('-'))).to eq(id)
      expect(described_class.dashed("  #{id.upcase.delete('-')}  ")).to eq(id)
    end

    it 'answers nil for anything else' do
      expect(described_class.dashed('abc')).to be_nil
      expect(described_class.dashed('')).to be_nil
      expect(described_class.dashed(nil)).to be_nil
      expect(described_class.dashed("#{id}x")).to be_nil
    end
  end
end
