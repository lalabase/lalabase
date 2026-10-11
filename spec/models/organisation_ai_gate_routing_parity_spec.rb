# frozen_string_literal: true

require 'rails_helper'

# What: the AI availability gates must predict what the Factory actually does.
# Type: Model spec, both sides asserted in the same example wherever it is cheap.
# Why (philosophy): review round 2 found two rules that were spelled out per call
#   site, each with exactly one site reading them differently — and neither wrong
#   site FAILED. They answered plausibly and differently, which is worse: the
#   endpoint rule made the gate tell a customer semantic search was unavailable on a
#   lane the Factory routed happily, and the purpose rule kept a package "available"
#   after an operator edit until the provider raised. Both now come off the record
#   (AiCredentialProviderRules#usable_for?); these examples are what stops a fourth
#   site from re-deriving them.
# Contract: gate and route agree — on the endpoint COLUMN, and on purpose+endpoint
#   for the curated chat lane just as they always did for embeddings.
RSpec.describe 'AI gates vs. the routing they predict', type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # The gate was the ONE place still reading additional_config['uri_base'] alone
  # while the Factory had moved to the api_base column (S2). All three EU presets
  # fill the column and set no legacy key, so this was not a legacy corner.
  describe 'the system embedding gate and the api_base COLUMN' do
    let!(:column_only) do
      create(:ai_credential, :openai_compatible, :active, :not_metered,
             purpose: 'embedding', api_base: 'https://column.internal/v1',
             default_model: 'bge-1024', additional_config: {})
    end

    before { organisation.update!(embedding_provider: 'openai_compatible') }

    it 'says yes to a credential whose endpoint lives in the column' do
      expect(organisation.has_valid_embedding_configuration?('openai_compatible')).to be(true)
    end

    it 'and the Factory names that same endpoint' do
      expect(Lalabase::Llm::Factory.for_embeddings(organisation, space: :configured).api_base)
        .to eq('https://column.internal/v1')
    end

    it 'still says no when neither column nor legacy key carries an endpoint' do
      column_only.update!(api_base: nil, additional_config: {})
      Rails.cache.clear

      expect(organisation.has_valid_embedding_configuration?('openai_compatible')).to be(false)
    end

    it 'still serves a legacy row that only has uri_base' do
      column_only.update!(api_base: nil, additional_config: { 'uri_base' => 'https://legacy.internal/v1' })
      Rails.cache.clear

      expect(organisation.has_valid_embedding_configuration?('openai_compatible')).to be(true)
    end
  end

  # The curated CHAT lane asked only `enabled?`, while its embedding twin had asked
  # for purpose and endpoint since R1/S2 — an asymmetry that sat in one file.
  describe 'the curated chat gate and the credential it will actually use' do
    let(:chat_credential) do
      create(:ai_credential, :openai_compatible, :not_metered, purpose: 'both',
                                                               api_base: 'https://chat.internal/v1',
                                                               default_model: 'mistral-small-latest')
    end

    let(:embedding_credential) do
      create(:ai_credential, :openai_compatible, :embedding_only, api_base: 'https://emb.internal/v1')
    end

    let(:package) do
      pkg = create(:ai_package, embedding_credential: embedding_credential,
                                embedding_model: 'mistral-embed', embedding_dims: 1024)
      AiPackageTier::KEYS.each_with_index do |key, index|
        pkg.tiers.create!(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                          position: index, chat_credential: chat_credential)
      end
      pkg
    end

    before { organisation.update!(ai_package: package, ai_package_tier_key: 'fast') }

    it 'is available while the rung credential can actually chat' do
      expect(organisation.has_valid_ai_configuration?('openai_compatible')).to be(true)
    end

    # The operator edit is the reachable path: nothing forbids narrowing the purpose
    # of a credential a published package references (that lock is a separate,
    # deliberately deferred slice).
    it 'refuses once the credential is narrowed to embedding-only' do
      chat_credential.update!(purpose: 'embedding')

      expect(organisation.reload.has_valid_ai_configuration?('openai_compatible')).to be(false)
    end

    # `api_base` carries no presence validation, so a cleared endpoint is a valid row.
    it 'refuses once the endpoint is cleared — openai_compatible has no vendor default' do
      chat_credential.update!(api_base: nil, additional_config: {})

      expect(organisation.reload.has_valid_ai_configuration?('openai_compatible')).to be(false)
    end

    # The whole point: the gate must PREDICT the routing, not merely differ from it.
    it 'and the routing refuses the same narrowing, loudly' do
      chat_credential.update!(purpose: 'embedding')

      expect { Lalabase::Llm::Factory.for_chat(organisation.reload) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError, /cannot serve chat/)
    end

    it 'and refuses the cleared endpoint the same way' do
      chat_credential.update!(api_base: nil, additional_config: {})

      expect { Lalabase::Llm::Factory.for_chat(organisation.reload) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError, /cannot serve chat/)
    end
  end

  # The shared vocabulary itself — one lane question, asked of the record.
  describe 'AiCredential#usable_for?' do
    it 'reads the lane off the purpose, not off a caller-side constant' do
      chat_only = build(:ai_credential, :not_metered, provider: 'openai', purpose: 'chat')
      both = build(:ai_credential, :not_metered, provider: 'openai', purpose: 'both')

      expect(chat_only.usable_for?(:chat)).to be(true)
      expect(chat_only.usable_for?(:embedding)).to be(false)
      expect(both.usable_for?(:chat)).to be(true)
      expect(both.usable_for?(:embedding)).to be(true)
    end

    it 'refuses a disabled credential on either lane' do
      disabled = build(:ai_credential, :not_metered, :disabled, provider: 'openai', purpose: 'both')

      expect(disabled.usable_for?(:chat)).to be(false)
      expect(disabled.usable_for?(:embedding)).to be(false)
    end

    it 'demands an endpoint only where there is no vendor default' do
      openai = build(:ai_credential, :not_metered, provider: 'openai', purpose: 'both',
                                                   api_base: nil, additional_config: {})
      compatible = build(:ai_credential, :not_metered, provider: 'openai_compatible', purpose: 'both',
                                                       api_base: nil, additional_config: {})

      expect(openai.usable_for?(:chat)).to be(true)
      expect(compatible.usable_for?(:chat)).to be(false)
    end

    it 'rejects an unknown lane rather than answering it' do
      expect { build(:ai_credential).usable_for?(:vision) }.to raise_error(ArgumentError, /vision/)
    end
  end
end
