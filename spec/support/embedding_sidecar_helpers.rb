# frozen_string_literal: true

# Opt-in helpers for specs that exercise the RETRIEVAL path after embedding v2
# PR 4b (read switch): reads no longer run over the inline vector columns but over
# the content_embeddings sidecar. A spec that creates a record without seeding a
# sidecar row therefore finds nothing.
#
# DELIBERATELY NOT a factory after(:create) callback: the PR-2/PR-3 specs assert
# exact ContentEmbedding row COUNTS (write-both, backfill, orphan GC), and an
# automatic mirror row would silently flip those numbers. Opt in per spec instead.
module EmbeddingSidecarHelpers
  # The default vector space every write path stamps for an org without embedding
  # BYOK config (Lalabase::Llm::Factory + Provider::DEFAULT_EMBEDDING_DIMS) — and
  # what the :content_embedding factory already defaults to.
  DEFAULT_EMBEDDING_SPACE = {
    embedding_provider: 'openai',
    embedding_model: 'text-embedding-3-small',
    embedding_dims: 1536
  }.freeze

  # Forces the EXACT vector path for the current example, by taking plain index
  # scans away from the planner (pgvector's HNSW index is only reachable as an
  # ordering Index Scan, so this makes it unusable and Postgres sorts exactly).
  # SET LOCAL is scoped to the example's fixture transaction.
  #
  # WHY retrieval specs need this — a real trap, not cosmetics: transactional
  # fixtures roll back thousands of content_embeddings inserts, and every one leaves
  # a DEAD entry in the HNSW index. pgvector 0.6.0 has no iterative index scan: a
  # scan visits at most `ef_search` index entries and only THEN checks visibility
  # plus the join/org/provenance filters. A burst of examples therefore burns the
  # whole budget on dead entries and returns ZERO rows although the example seeded a
  # matching live row — reproduced as `Index Scan using idx_ce_fragment_1536_l2 ...
  # rows=0` with exactly one live row in the table. Whether it hits depends on how
  # far autovacuum has caught up, i.e. it is a timing race: flaky in CI, and raising
  # ef_search only moves the threshold (verified: even the maximum 1000 does not hold).
  #
  # These specs pin retrieval LOGIC — filters, gates, ordering, tenant boundaries —
  # not ANN recall, and they run on data volumes where the exact scan is what
  # production would choose anyway (an org-scoped query takes the b-tree + sort,
  # sheet §2.1). The index's own usability is pinned separately and deliberately by
  # the two EXPLAIN guards, which force index scans instead.
  #
  # The under-fetch property itself is REAL and documented
  # (doc/embedding_v2_pr4b_read_switch_plan.md §3.5 + §8): the answer there is the
  # pgvector >= 0.8.0 upgrade with hnsw.iterative_scan, not a code change here.
  def pin_exact_vector_scans
    ActiveRecord::Base.connection.execute('SET LOCAL enable_indexscan = off')
  end

  # Gives a record the sidecar row a write path would have created for it: default
  # triple, indexed: true, the given vector.
  #
  # Until PR 7 this took the vector FROM the record's inline column
  # (mirror_embedding_to_sidecar) — that column is gone, so the vector is now an
  # explicit argument. Callers that used to seed the record with an inline vector
  # and mirror afterwards pass that vector here instead; there is no longer a second
  # place it could be hiding.
  #
  # Runs inside with_tenant(record.organisation) because acts_as_tenant would
  # otherwise stamp the ambient tenant onto the row — which matters precisely for
  # the cross-org isolation examples that seed a FOREIGN org's record.
  #
  # @param vector [Array<Float>, nil] nil/blank seeds nothing and returns nil — a
  #   record without an embedding has no sidecar row, and that IS the production state
  # @return [ContentEmbedding, nil]
  def seed_sidecar_embedding(record, vector:, **overrides)
    return nil if vector.blank?

    ActsAsTenant.with_tenant(record.organisation) do
      create(:content_embedding,
             embeddable: record,
             organisation: record.organisation,
             embedding: vector.to_a,
             **DEFAULT_EMBEDDING_SPACE,
             indexed: true,
             **overrides)
    end
  end

  # Pins the org's CURRENT vector space to the default triple for EVERY org.
  #
  # Needed because Embeddings::NearestNeighbors resolves the triple through
  # Lalabase::Llm::Factory.embedding_space_for, which resolves a credential and
  # raises MissingCredentialError when neither BYOK nor a system AiCredential
  # exists — the normal state in specs. The stubbed value is exactly what the real
  # resolution returns for an unconfigured org, so this removes setup noise, not
  # behaviour. Specs that want to prove the resolution ITSELF (factory_spec) must
  # not use this.
  def stub_default_embedding_space
    stub_embedding_space
  end

  # Same, for a chosen dimension (embedding v2 PR 5, sheet §7.2): the org's current
  # space with `dims` as the third element of the triple. A non-default dim also gets
  # a plausible provider/model, so the stub stays a triple a real resolution could
  # produce (never "3-small at 768 dims").
  #
  # @param dims [Integer] one of Organisation::SUPPORTED_DIMS
  # @return [Hash] the stubbed triple, so callers can seed matching sidecar rows
  def stub_embedding_space(dims: DEFAULT_EMBEDDING_SPACE[:embedding_dims])
    space =
      if dims == DEFAULT_EMBEDDING_SPACE[:embedding_dims]
        DEFAULT_EMBEDDING_SPACE
      else
        { embedding_provider: 'openai_compatible',
          embedding_model: "test-embed-#{dims}",
          embedding_dims: dims }
      end
    allow(Lalabase::Llm::Factory).to receive(:embedding_space_for).and_return(space)
    space
  end
end

RSpec.configure do |config|
  config.include EmbeddingSidecarHelpers
end
