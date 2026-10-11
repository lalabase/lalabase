# frozen_string_literal: true

module Lalabase
  # Embeds a free-text query for pgvector search, with a length cap applied
  # before the API call. Shared by ProjectRag::Retriever (baseline retrieval)
  # and Tools::SearchCodeSymbols (mid-answer drill-down) so the cap + the
  # provider resolution live in ONE place instead of two near-identical helpers
  # with two separately-named 8000 constants.
  module QueryEmbedding
    # OpenAI-family embedding models cap around 8191 tokens; 8000 chars (~2k
    # tokens) is a safe, provider-agnostic ceiling that also caps cost/latency on
    # pathologically long queries.
    MAX_QUERY_LENGTH = 8000

    module_function

    # @param provider [#embed_with_usage, nil] inject for tests / reuse; defaults
    #   to the org's configured embedding provider.
    # @return [Array<Float>] the query embedding (metering is a side effect).
    def embed(query, organisation, provider: nil)
      # An INJECTED provider owns its own model choice — the caller picked it
      # deliberately — so no space is resolved for it (and no credential read happens).
      # Everything else resolves the ACTIVE space, never the configured one.
      model = provider ? nil : active_model(organisation)
      # The ACTIVE space (embedding v2 PR 6a, review blocker B1): between the moment an
      # admin sets a target configuration and the flip, the rows being searched still
      # belong to the OLD space. Embedding the query with the new model would compare
      # vectors across incompatible spaces — retrieval broken for the whole build
      # window, silently.
      provider ||= Lalabase::Llm::Factory.for_feature(:semantic_search, organisation, space: :active)
      result = provider.embed_with_usage(text: query.to_s[0, MAX_QUERY_LENGTH], model: model)
      # ONE metering row per search query (decision 1A, test 12). Best-effort —
      # record_embedding never raises, so a metering hiccup can't break search.
      Lalabase::Llm::UsageTracking.record_embedding(
        organisation: organisation, provider: provider,
        total_tokens: result[:total_tokens], action: Lalabase::Llm::ActionRegistry::SEMANTIC_SEARCH,
        call_type: 'semantic_search'
      )
      result[:embedding]
    end

    # The model of the org's ACTIVE space, passed explicitly to the embed call.
    #
    # This is load-bearing, not decoration: OpenAiProvider and GoogleVertexProvider
    # answer #default_embedding_model from a CONSTANT and ignore the configured model
    # (the latter deliberately — a google credential's default_model is its CHAT
    # model). Without the override the pointer would select the right ROWS while the
    # query vector came from the wrong MODEL: the 2026-07-30 production incident with
    # a pointer in front of it. Pinned by a spec on the OPENAI path specifically —
    # on openai_compatible the same spec would pass either way and prove nothing.
    def active_model(organisation)
      Lalabase::Llm::Factory.embedding_space_for(organisation, space: :active)[:embedding_model]
    end
  end
end
