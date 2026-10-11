# frozen_string_literal: true

module Lalabase
  module Indexer
    # Builds the embedding-provenance stamp every embedded record carries: the
    # {provider, model, dims} TRIPLE of the content_embeddings sidecar. ONE source so
    # a provider/model/dims change updates all persist paths together instead of
    # leaving one silently stamped with the old provenance.
    #
    # The vector space is only unique as (provider, model, dims) — main plan §3.2.
    # Until PR 7 there was a second shape here, the provenance PAIR of the four inline
    # tables; those columns are gone, and with them the pair.
    #
    # Helpers (not Provider methods) on purpose: callers pass an embedding provider
    # that is usually an instance_double in specs — this just reads the already-
    # stubbed provider_name / default_embedding_model / expected_embedding_dims, so
    # no extra stubbing (expected_embedding_dims is public since PR 2 for exactly
    # this reason — the provenance and the delta-reindex read it).
    module EmbeddingColumns
      module_function

      def from(provider)
        { embedding_provider: provider.provider_name,
          embedding_model: provider.default_embedding_model,
          embedding_dims: provider.expected_embedding_dims }
      end
    end
  end
end
