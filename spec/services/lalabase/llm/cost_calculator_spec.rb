# frozen_string_literal: true

# What: THE single cost source that replaces the two deleted 2024 price tables.
# Why:  Cost must come from the active system credential's price fields (data, not
#       code), must keep sub-cent precision (the reason cost_cents became decimal),
#       and must be 0 for BYOK — a BYOK org pays its provider directly, so its usage
#       is neither our cost nor attributed to a system credential.
require 'rails_helper'

RSpec.describe Lalabase::Llm::CostCalculator do
  describe '.per_million' do
    it 'computes (tokens / 1M) * price as BigDecimal cents' do
      expect(described_class.per_million(500_000, 60)).to eq(BigDecimal('30'))
    end

    it 'keeps sub-cent precision (the whole reason for the decimal column)' do
      # 1000 tokens at 15 cents / 1M = 0.015 cents — used to round to 0 as integer.
      expect(described_class.per_million(1_000, 15)).to eq(BigDecimal('0.015'))
    end

    it 'is 0 for a not-yet-configured (nil) price' do
      expect(described_class.per_million(1_000, nil)).to eq(0)
    end

    it 'is 0 for zero tokens (boundary)' do
      expect(described_class.per_million(0, 60)).to eq(0)
    end

    it 'is 0 — never NEGATIVE — for negative tokens (kills removal of the token guard)' do
      # tokens: 0 alone can't prove the guard exists: (0/1M)*price is 0 with or without it.
      # A negative count is the only input that would go negative if the `tokens <= 0`
      # guard were removed, so this is the test that actually pins the guard.
      expect(described_class.per_million(-100, 60)).to eq(0)
    end
  end

  describe '.chat_cents' do
    let(:credential) { build(:ai_credential, input_cost_per_1m_cents: 15, output_cost_per_1m_cents: 60) }

    it 'sums input and output cost from the credential price fields' do
      # 1M input @15 + 1M output @60 = 75 cents
      expect(
        described_class.chat_cents(credential: credential, input_tokens: 1_000_000, output_tokens: 1_000_000)
      ).to eq(BigDecimal('75'))
    end

    it 'applies the INPUT price to input tokens and the OUTPUT price to output tokens (not swapped)' do
      # Asymmetric tokens: 1M input @15 = 15, 2M output @60 = 120 → 135. A symmetric
      # 1M/1M test (= 75) survives an input/output price swap; this one does not.
      expect(
        described_class.chat_cents(credential: credential, input_tokens: 1_000_000, output_tokens: 2_000_000)
      ).to eq(BigDecimal('135'))
    end

    it 'is 0 when there is no billing credential (BYOK / no system credential)' do
      expect(described_class.chat_cents(credential: nil, input_tokens: 1_000, output_tokens: 1_000)).to eq(0)
    end
  end

  describe '.embedding_cents' do
    it 'computes from the embedding price field' do
      credential = build(:ai_credential, embedding_cost_per_1m_cents: 2)
      expect(described_class.embedding_cents(credential: credential, tokens: 1_000_000)).to eq(BigDecimal('2'))
    end

    it 'is 0 when credential is nil' do
      expect(described_class.embedding_cents(credential: nil, tokens: 1_000)).to eq(0)
    end
  end

  describe '.billing_credential' do
    let!(:system_credential) { create(:ai_credential, :active, provider: 'openai') }

    it 'returns the active system credential for a non-BYOK org' do
      org = create(:organisation)
      expect(described_class.billing_credential(org, 'openai')).to eq(system_credential)
    end

    it 'returns nil for a BYOK org — and that makes the cost 0 end-to-end' do
      org = create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-org-own-key-1234567890')

      credential = described_class.billing_credential(org, 'openai')
      expect(credential).to be_nil
      expect(described_class.chat_cents(credential: credential, input_tokens: 10_000, output_tokens: 10_000)).to eq(0)
    end

    it 'returns nil when no active system credential exists for the provider' do
      system_credential.update!(active: false)
      org = create(:organisation)
      expect(described_class.billing_credential(org, 'openai')).to be_nil
    end
  end
end
