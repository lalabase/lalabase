# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# 1. The query cap (boundary n-1/n/n+1) and the one-metering-row-per-query rule.
# 2. Review blocker B1 (embedding v2 PR 6a): the SEARCH QUERY is embedded with the
#    ACTIVE vector space's model, never the configured one. A config change alone must
#    not move serving — otherwise every query during a staged switch is embedded with
#    the new model and compared against old-space rows, and retrieval silently returns
#    nothing for the entire build window.
#
# The B1 block is deliberately written on the OPENAI path. On openai_compatible the
# provider reads its model from the configuration, so the assertion would hold with or
# without the fix and prove nothing. OpenAiProvider answers #default_embedding_model
# from a CONSTANT — it is the path where forgetting the explicit `model:` actually
# breaks, and therefore the only path where the test has teeth.
RSpec.describe Lalabase::QueryEmbedding do
  let(:organisation) { create(:organisation) }
  let(:vec)          { Array.new(1536, 0.1) }
  # S3: the metering path resolves provider_name and reads total_tokens off the
  # usage-aware embed method, so the double stubs both.
  let(:provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai',
                                                   embed_with_usage: { embedding: vec, total_tokens: 5 })
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe '.embed' do
    it 'embeds the query via the injected provider' do
      expect(described_class.embed('hello', organisation, provider: provider)).to eq(vec)
      # model: nil — an injected provider owns its own model choice, and resolving a
      # space for it would mean a credential read the caller did not ask for.
      expect(provider).to have_received(:embed_with_usage).with(text: 'hello', model: nil)
    end

    it 'truncates a query longer than the cap before embedding (n+1 boundary)' do
      long = 'q' * (described_class::MAX_QUERY_LENGTH + 500)
      described_class.embed(long, organisation, provider: provider)
      expect(provider).to have_received(:embed_with_usage)
        .with(text: 'q' * described_class::MAX_QUERY_LENGTH, model: nil)
    end

    it 'passes a query exactly at the cap through unchanged (n boundary)' do
      exact = 'r' * described_class::MAX_QUERY_LENGTH
      described_class.embed(exact, organisation, provider: provider)
      expect(provider).to have_received(:embed_with_usage).with(text: exact, model: nil)
    end

    it 'resolves the org embedding provider via Factory when none is injected' do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).with(organisation, space: :active)
                                                               .and_return(provider)
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for).with(organisation, space: :active)
                                                                    .and_return(embedding_model: 'm')
      described_class.embed('x', organisation)
      expect(Lalabase::Llm::Factory).to have_received(:for_embeddings).with(organisation, space: :active)
    end

    it 'records exactly one semantic_search usage row per query (test 12)' do
      expect { described_class.embed('hello', organisation, provider: provider) }
        .to change { AiUsage.where(organisation: organisation, action: 'semantic_search').count }.by(1)
    end

    it { expect(described_class::MAX_QUERY_LENGTH).to eq(8000) }
  end

  # [B1] The staged switch: configuration already points at the target space, the
  # pointer still names the old one. Everything about serving must follow the POINTER.
  describe 'active-space routing during a staged switch (B1)' do
    let!(:credential) do
      create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-system')
    end
    # The OLD space, still serving: a model that is NOT the OpenAiProvider constant.
    # That difference is the entire point — with the constant on both sides the test
    # could not tell a correct implementation from a broken one.
    let!(:active_space) do
      ActsAsTenant.with_tenant(organisation) do
        EmbeddingSpace.create!(organisation: organisation, embedding_provider: 'openai',
                               embedding_model: 'text-embedding-ada-002', embedding_dims: 1536)
      end
    end
    let(:spy_provider) do
      instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai',
                                                     embed_with_usage: { embedding: vec, total_tokens: 5 })
    end

    before do
      organisation.update!(active_embedding_space_id: active_space.id,
                           # Configuration ALREADY points elsewhere — the target of the switch.
                           embedding_provider: 'openai', embedding_dims: 1024)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(spy_provider)
    end

    it 'embeds the query with the ACTIVE space model, not the configured/default one' do
      described_class.embed('hello', organisation)

      expect(spy_provider).to have_received(:embed_with_usage)
        .with(text: 'hello', model: 'text-embedding-ada-002')
    end

    it 'asks the Factory for the ACTIVE space, never the configured one' do
      described_class.embed('hello', organisation)

      expect(Lalabase::Llm::Factory).to have_received(:for_embeddings).with(organisation, space: :active)
    end

    # Negative control for the one above: the constant the provider WOULD have used is
    # a different string, so a regression (dropping `model:`) changes the assertion's
    # outcome rather than being invisible.
    it 'does not fall back to the provider constant while an active space names another model' do
      described_class.embed('hello', organisation)

      expect(spy_provider).not_to have_received(:embed_with_usage)
        .with(hash_including(model: Lalabase::Llm::OpenAiProvider::DEFAULT_EMBEDDING_MODEL))
    end

    # Without a pointer there is nothing to follow: :active falls back to the effective
    # configuration (series plan §5.3), which is what a fresh org needs.
    it 'falls back to the configured space when the org has no pointer yet' do
      organisation.update!(active_embedding_space_id: nil)

      described_class.embed('hello', organisation)

      expect(spy_provider).to have_received(:embed_with_usage)
        .with(text: 'hello', model: Lalabase::Llm::OpenAiProvider::DEFAULT_EMBEDDING_MODEL)
    end
  end
end
