# frozen_string_literal: true

module Lalabase
  module Indexer
    # Embeds a batch of extracted symbol hashes and inserts them as CodeSymbol
    # rows for one repository. Shared by the initial index (ProjectIndexerJob —
    # full per-repo replace) and the incremental re-index (RepoReindexJob —
    # per-file replace). insert_all → no per-row ActiveRecord callbacks.
    module SymbolPersistence
      # Raised when the embedding provider returns a different number of vectors
      # than symbols we asked it to embed — see the guard in .persist for why we
      # refuse to insert in that case.
      class EmbeddingCountMismatch < StandardError; end

      module_function

      # @param repo [ProjectRepository]
      # @param embed_provider [#embed_batch, #provider_name, #default_embedding_model]
      # @param symbols [Array<Hash>] extractor output (signature, qualified_name, …)
      # @return [Integer] number of rows inserted
      def persist(repo:, embed_provider:, symbols:)
        return 0 if symbols.empty?

        embeddings = embed_provider.embed_batch(texts: symbols.map { |s| s[:signature] })
        # One embedding per symbol is the contract. If the provider returns fewer
        # (partial response / bug), `zip` would pad rows with a nil embedding and
        # insert_all would SILENTLY persist unsearchable symbols. Fail loudly so
        # the job's rescue marks the index `failed` (and can retry) instead.
        raise EmbeddingCountMismatch, "#{symbols.size} symbols, #{embeddings.size} embeddings" if embeddings.size != symbols.size

        # Provenance stamped once for the whole batch: the full triple on the sidecar
        # rows (embedding v2 PR 2). The CodeSymbol rows carry no provenance since
        # PR 7 — the sidecar row IS the vector-space statement.
        triple = Lalabase::Indexer::EmbeddingColumns.from(embed_provider)

        # Pre-generate the CodeSymbol UUIDs client-side so each sidecar row can point
        # at its symbol deterministically — no reliance on insert_all RETURNING order
        # (embedding v2 PR 2, §3.4b).
        rows = symbols.map do |sym|
          {
            id: SecureRandom.uuid,
            organisation_id: repo.organisation_id,
            project_repository_id: repo.id,
            symbol_type: sym[:symbol_type],
            name: sym[:name],
            qualified_name: sym[:qualified_name],
            file_path: sym[:file_path],
            start_line: sym[:start_line],
            end_line: sym[:end_line],
            signature: sym[:signature],
            language: sym[:language],
            metadata: sym[:metadata] || {}
          }
        end
        # Sidecar rows, one per symbol, keyed to the pre-generated UUID; source_hash
        # over the EXACT signature that was embedded (== row[:signature]). The vector
        # comes from `embeddings`, which is index-aligned with `rows` (both derive
        # from `symbols` in order, and the count guard above proved the sizes match).
        sidecar_rows = rows.each_with_index.map do |row, i|
          {
            organisation_id: row[:organisation_id],
            embeddable_type: 'CodeSymbol', embeddable_id: row[:id],
            **triple,
            embedding: embeddings[i],
            source_hash: ContentEmbedding.source_hash_for(row[:signature]),
            indexed: true, embedded_at: Time.current
          }
        end
        # insert_all: DELIBERATE bulk insert (performance with many symbols); the data
        # comes from the extractor, so model validation is intentionally bypassed here.
        # Both inserts share ONE transaction (m1): joins the caller's
        # CodeSymbol.transaction (ProjectIndexerJob / RepoReindexJob) when present, and
        # is self-sufficient for any future caller without one. Timestamps are filled by
        # insert_all automatically on both tables.
        CodeSymbol.transaction do
          CodeSymbol.insert_all(rows) if rows.any?
          ContentEmbedding.insert_all(sidecar_rows) if sidecar_rows.any?
        end
        rows.size
      end
    end
  end
end
