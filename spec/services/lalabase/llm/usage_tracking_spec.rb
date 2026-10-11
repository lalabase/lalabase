# frozen_string_literal: true

# What: the single AiUsage-writing seam shared by the chat job and the migrated
#   chat callers.
# Why:  attribution + costing must follow the credential the call actually ran on
#   (Provider#billing_credential, resolved once by the Factory — P0; BYOK ⇒ nil),
#   the metadata shape must be identical everywhere, and a tracking failure must
#   never bubble up into the user-facing feature. WHICH credential a call routes
#   to (BYOK columns, per-kind, packages) is the Factory's contract, pinned there.
require 'rails_helper'

RSpec.describe Lalabase::Llm::UsageTracking do
  # Default double: a BYOK-routed provider (carries no system credential).
  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai', billing_credential: nil) }

  def provider_on(credential, klass: Lalabase::Llm::OpenAiProvider, provider_name: 'openai')
    instance_double(klass, provider_name: provider_name, billing_credential: credential)
  end

  describe '.record' do
    it 'attributes to the credential carried by the provider and stores the computed decimal cost' do
      credential = create(:ai_credential, :active, provider: 'openai',
                                                   input_cost_per_1m_cents: 15, output_cost_per_1m_cents: 60)
      org = create(:organisation)

      usage = described_class.record(
        organisation: org, provider: provider_on(credential),
        token_usage: { input_tokens: 1_000_000, output_tokens: 1_000_000, total_tokens: 2_000_000, estimated: false },
        model: 'gpt-4o-mini', call_type: 'document_summary', action: 'summary'
      )

      expect(usage).to be_persisted
      expect(usage.ai_credential).to eq(credential)
      expect(usage.tokens_used).to eq(2_000_000)
      expect(usage.cost_cents).to eq(BigDecimal('75')) # 1M@15 + 1M@60 cents
      expect(usage.model_used).to eq('gpt-4o-mini')
      expect(usage.metadata['method']).to eq('document_summary')
      expect(usage.metadata['estimated_tokens']).to be(false)
    end

    it 'attributes BYOK usage (provider without credential) to nil with zero cost' do
      # An active system credential exists — but the provider was routed BYOK by
      # the Factory (billing_credential nil), so nothing may be attributed to it.
      create(:ai_credential, :active, provider: 'openai')
      org = create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-org-own-key-1234567890')

      usage = described_class.record(
        organisation: org, provider: provider,
        token_usage: { input_tokens: 100, output_tokens: 100, total_tokens: 200 },
        model: 'gpt-4o-mini', call_type: 'ask_ai', action: 'post_ai'
      )

      expect(usage.ai_credential).to be_nil
      expect(usage.cost_cents).to eq(0)
    end

    # P0 regression (doc/ki_pakete_plan.md §4.1): with two credentials of the same
    # provider, the bill must land on the one that SERVED the call — a name-based
    # re-resolution would attribute to the provider-active credential instead.
    it 'bills the credential the call ran on, not the provider-active one' do
      create(:ai_credential, :active, provider: 'openai_compatible', display_name: 'Mistral EU')
      package_credential = create(:ai_credential, provider: 'openai_compatible', active: false,
                                                  display_name: 'IONOS DE', input_cost_per_1m_cents: 10,
                                                  output_cost_per_1m_cents: 20)
      org = create(:organisation)

      usage = described_class.record(
        organisation: org,
        provider: provider_on(package_credential, klass: Lalabase::Llm::OpenAiCompatibleProvider,
                                                  provider_name: 'openai_compatible'),
        token_usage: { input_tokens: 1_000_000, output_tokens: 0, total_tokens: 1_000_000 },
        call_type: 'chat_streaming', action: 'chat_message'
      )

      expect(usage.ai_credential).to eq(package_credential)
      expect(usage.cost_cents).to eq(BigDecimal('10'))
      expect(usage.metadata['effective_provider']).to eq('IONOS DE')
    end

    it 'keeps a sub-cent cost instead of rounding it to 0 (decimal column)' do
      credential = create(:ai_credential, :active, provider: 'openai',
                                                   input_cost_per_1m_cents: 15, output_cost_per_1m_cents: 60)
      org = create(:organisation)

      usage = described_class.record(
        organisation: org, provider: provider_on(credential),
        token_usage: { input_tokens: 1_000, output_tokens: 0, total_tokens: 1_000 },
        call_type: 'ticket_summary', action: 'summary'
      )

      # 1000 tokens @ 15 cents / 1M = 0.015 cents — the integer column rounded this to 0.
      expect(usage.cost_cents).to eq(BigDecimal('0.015'))
    end

    it 'never raises when tracking fails — a side effect must not break the feature' do
      org = create(:organisation)
      allow(AiUsage).to receive(:track_usage).and_raise(StandardError, 'db down')

      result = nil
      expect { result = described_class.record(organisation: org, provider: provider, token_usage: {}, call_type: 'x', action: 'chat_message') }
        .not_to raise_error
      expect(result).to be_nil
    end

    # Credits come from the ActionRegistry keyed on `action`, NOT from tokens (chat
    # is flat-priced). Pins that the action actually drives the booked credits — a
    # mutation hardcoding credits or passing the wrong action key dies here.
    it 'books the flat registry credit price for a chat action, independent of tokens' do
      usage = described_class.record(
        organisation: create(:organisation), provider: provider,
        token_usage: { total_tokens: 999_999 }, call_type: 'chat_streaming', action: 'chat_message'
      )
      expect(usage.credits_used).to eq(Lalabase::Llm::ActionRegistry.credits_for('chat_message')).and eq(2)
    end
  end

  describe '.record_embedding' do
    let(:org) { create(:organisation) }

    it 'books token-metered credits (ceil per 1000) and stores action + subject' do
      usage = described_class.record_embedding(
        organisation: org, provider: provider, total_tokens: 2500,
        action: 'document_indexing', subject: org, fragment_count: 4
      )
      expect(usage.credits_used).to eq(3) # ceil(2500 / 1000)
      expect(usage.action).to eq('document_indexing')
      expect(usage.subject).to eq(org)
      expect(usage.metadata['fragment_count']).to eq(4)
    end

    # BYOK: logged for transparency (credits computed) but never billed to us —
    # the Factory routed the call on the org's own key, so the provider carries
    # no system credential.
    it 'logs BYOK embedding usage with credits but zero cost and no credential' do
      byok_org = create(:organisation, embedding_provider: 'openai', embedding_access_token: 'sk-own-emb-key-123456')
      create(:ai_credential, :active, provider: 'openai') # system exists, but the call did not run on it
      usage = described_class.record_embedding(
        organisation: byok_org, provider: provider, total_tokens: 1500, action: 'document_indexing'
      )
      expect(usage.credits_used).to eq(2) # still computed (transparency)
      expect(usage.cost_cents).to eq(0)   # but not billed
      expect(usage.ai_credential).to be_nil
    end

    # P0: the bill follows the credential of the SPACE that served the call (the
    # provider carries it) — not a fresh lookup off the org's current embedding
    # columns, which can differ during a staged switch (chat-BYOK orgs, packages).
    it 'bills the credential carried by the provider, regardless of org chat BYOK' do
      credential = create(:ai_credential, :active, provider: 'openai', embedding_cost_per_1m_cents: 2)
      mixed_org = create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-own-chat-key-123456')
      usage = described_class.record_embedding(
        organisation: mixed_org, provider: provider_on(credential), total_tokens: 1_000_000,
        action: 'document_indexing'
      )
      expect(usage.ai_credential).to eq(credential) # embeddings ran on system → billed
      expect(usage.cost_cents).to eq(BigDecimal('2'))
    end
  end

  describe 'attribution: routing key in the provider column, effective name in metadata' do
    it 'keeps aggregation-by-routing-key working while recording the display name' do
      credential = create(:ai_credential, :active, provider: 'openai_compatible',
                                                   display_name: 'Mistral EU', api_base: 'https://m.eu/v1',
                                                   default_model: 'mistral-small')
      org = create(:organisation) # non-BYOK for openai_compatible → uses the system credential
      compat = provider_on(credential, klass: Lalabase::Llm::OpenAiCompatibleProvider,
                                       provider_name: 'openai_compatible')

      usage = described_class.record(
        organisation: org, provider: compat,
        token_usage: { input_tokens: 100, output_tokens: 50, total_tokens: 150 },
        call_type: 'chat_streaming', action: 'chat_message'
      )

      # provider column = ROUTING KEY, so Admin::AiUsage.by_provider('openai_compatible') still matches it.
      expect(usage.provider).to eq('openai_compatible')
      # ...and the effective display name is preserved for provenance in metadata.
      expect(usage.metadata['effective_provider']).to eq('Mistral EU')
      expect(usage.ai_credential).to eq(credential)
    end

    it 'OMITS effective_provider from metadata when the credential has no display name' do
      # The value is compacted out (not stored as nil / not duplicated as the key). This
      # kills a mutation that always writes effective_provider regardless of display_name.
      credential = create(:ai_credential, :active, provider: 'openai', display_name: nil)
      org = create(:organisation)

      usage = described_class.record(
        organisation: org, provider: provider_on(credential),
        token_usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }, call_type: 'chat_streaming', action: 'chat_message'
      )

      expect(usage.provider).to eq('openai') # routing key, still present
      expect(usage.metadata).not_to have_key('effective_provider')
    end
  end

  # S2 consolidation guard: the whole point is ONE tracking path. After deleting
  # AiClientWrapper, no other app file may write an AiUsage row directly — the chat
  # job and all migrated callers must go through .record.
  describe 'single implementation (structural guard)' do
    it 'is the ONLY place in app/ that calls AiUsage.track_usage' do
      # Skip comment lines so the doc example in ai_usage.rb ("# AiUsage.track_usage(")
      # isn't mistaken for a real caller.
      files_with_call = Dir.glob(Rails.root.join('app/**/*.rb')).select do |path|
        File.readlines(path).any? { |line| line !~ /\A\s*#/ && line.include?('AiUsage.track_usage(') }
      end
      callers = files_with_call.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }

      expect(callers).to contain_exactly('app/services/lalabase/llm/usage_tracking.rb')
    end
  end
end
