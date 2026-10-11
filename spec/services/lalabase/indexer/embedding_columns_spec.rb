# frozen_string_literal: true

require 'rails_helper'

# Provenance stamp builder (embedding v2 PR 2). `.from` is the full triple every
# sidecar row carries. It reads only the provider's PUBLIC interface (provider_name /
# default_embedding_model / expected_embedding_dims), so an instance_double with
# those three stubs is enough.
#
# The transitional second shape — `.inline_pair`, plus INLINE_DIMS and
# `.inline_writable?` — died with the inline columns in PR 7. What those pinned (a
# 1536-only write lane) has no successor: every dimension now takes the same path.
RSpec.describe Lalabase::Indexer::EmbeddingColumns do
  let(:provider) do
    instance_double(Lalabase::Llm::OpenAiProvider,
                    provider_name: 'openai',
                    default_embedding_model: 'text-embedding-3-small',
                    expected_embedding_dims: 1536)
  end

  describe '.from' do
    it 'is the full {provider, model, dims} triple for the sidecar' do
      expect(described_class.from(provider)).to eq(
        embedding_provider: 'openai',
        embedding_model: 'text-embedding-3-small',
        embedding_dims: 1536
      )
    end

    it 'reads the EFFECTIVE dim (expected_embedding_dims), not a hardcoded 1536' do
      allow(provider).to receive(:expected_embedding_dims).and_return(1024)
      expect(described_class.from(provider)[:embedding_dims]).to eq(1024)
    end
  end
end
