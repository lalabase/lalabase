# frozen_string_literal: true

require 'rails_helper'

# Guards the embedding write/query path against regressing to a hardcoded OpenAI
# embedder. After the provider abstraction, every embedding call resolves its
# provider via Lalabase::Llm::Factory / Lalabase::QueryEmbedding — the provider,
# model and endpoint are CONFIGURATION (org embedding_* columns / AiCredential),
# never literals in a consumer service.
#
# This is a source-text contract (grep-style), deliberately separate from the
# behavioural specs: it fails the moment someone reintroduces a hardcoded model,
# a raw OpenAI client, or the deleted EmbeddingService in the embedding path.
RSpec.describe 'Embedding provider hardcode guard' do
  # Locals (not constants) so they stay scoped to this guard and don't trip
  # Lint/ConstantDefinitionInBlock. Services that GENERATE or QUERY embeddings —
  # the model/provider/endpoint must come from the Factory, not a literal here.
  consumer_files = %w[
    app/services/embedding_processing_service.rb
    app/services/prompt_building_service.rb
    app/services/power_search_service.rb
    app/services/lalabase/query_embedding.rb
  ]

  forbidden = {
    /text-embedding-ada-002/ => 'a hardcoded embedding-model literal',
    /text-embedding-3-small/ => 'a hardcoded embedding-model literal (the model is config, resolve via Factory)',
    /OpenAI::Client/ => 'a direct OpenAI client (resolve via Lalabase::Llm::Factory instead)',
    /\bEmbeddingService\b/ => 'a reference to the removed legacy EmbeddingService'
  }

  consumer_files.each do |rel|
    describe rel do
      let(:source) { Rails.root.join(rel).read }

      it 'exists (guard list stays in sync with the codebase)' do
        expect(Rails.root.join(rel)).to exist
      end

      forbidden.each do |pattern, why|
        it "does not contain #{why}" do
          expect(source).not_to match(pattern)
        end
      end
    end
  end

  it 'the legacy hardcoded EmbeddingService is deleted' do
    expect(Rails.root.join('app/services/embedding_service.rb')).not_to exist
    expect { EmbeddingService }.to raise_error(NameError)
  end
end
