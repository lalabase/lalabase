# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::FenceGuard do
  describe '.sanitize' do
    it 'replaces a triple-backtick with three single-quotes + a space' do
      # Exact output asserted so a mutation of the replacement token is caught.
      expect(described_class.sanitize('```')).to eq("''' ")
    end

    it 'replaces every occurrence, not just the first (global gsub)' do
      result = described_class.sanitize('``` mid ``` end ```')
      expect(result).not_to include('```')
      expect(result.scan("''' ").size).to eq(3)
    end

    it 'leaves single and double backticks untouched (only triple is a fence breakout)' do
      expect(described_class.sanitize('`code` and ``x``')).to eq('`code` and ``x``')
    end

    it 'neutralises a triple-tilde fence (CommonMark accepts ~~~ fences too)' do
      expect(described_class.sanitize('~~~')).to eq("''' ")
    end

    it 'leaves single and double tildes untouched (e.g. ~strike~ markup)' do
      expect(described_class.sanitize('~strike~ and ~~x~~')).to eq('~strike~ and ~~x~~')
    end

    it 'neutralises mixed backtick and tilde fences in the same text' do
      result = described_class.sanitize('```ruby ~~~ end```')
      expect(result).not_to include('```')
      expect(result).not_to include('~~~')
    end

    it 'returns text without backticks unchanged' do
      expect(described_class.sanitize('plain signature(arg)')).to eq('plain signature(arg)')
    end

    it 'handles an empty string' do
      expect(described_class.sanitize('')).to eq('')
    end

    it 'coerces nil to an empty string (shared util must not raise on nil)' do
      expect(described_class.sanitize(nil)).to eq('')
    end

    it 'is callable as a module function' do
      expect(described_class).to respond_to(:sanitize)
    end
  end
end
