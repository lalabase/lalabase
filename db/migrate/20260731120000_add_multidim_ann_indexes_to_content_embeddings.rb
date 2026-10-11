# frozen_string_literal: true

# Embedding v2 PR 5 (doc/embedding_v2_pr5_multidim_plan.md §4): the 768 and 1024
# lanes of the expression-partial HNSW indexes on the sidecar. Same metrics per type
# as the 1536 lane — Fragment L2, CodeSymbol cosine (Embeddings::NearestNeighbors::METRICS
# is the truth per TYPE, not per dim); capabilities/visions stay exact by design.
# 3072/halfvec remains PR 5b.
#
# TWIN of db/migrate/20260719160000_add_ann_indexes_to_content_embeddings.rb — the
# mechanics (disable_ddl_transaction!, maintenance_work_mem, CONCURRENTLY +
# INVALID self-healing) are DELIBERATELY duplicated, not extracted: migrations are
# frozen history and a shared helper would couple old migrations to future
# refactorings. Unify at the third occurrence (that would be PR 5b), and keep both
# files in sync until then.
#
# The predicate sets are EMPTY on every existing installation (no org can have been
# on 768/1024 before this PR), so these builds are instant; the indexes grow
# incrementally with the first reindex of a 768/1024 org.
class AddMultidimAnnIndexesToContentEmbeddings < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  # See the twin migration for why a plain session-scoped SET is both possible and
  # sufficient here, and why this needs no superuser.
  MAINTENANCE_WORK_MEM = ENV.fetch('EMBEDDING_INDEX_MAINTENANCE_WORK_MEM', '2GB')

  # Fragment → vector_l2_ops, CodeSymbol → vector_cosine_ops, per dimension. Spelled
  # out rather than generated: the DDL stays greppable and diffable against the twin.
  INDEXES = {
    'idx_ce_fragment_768_l2' => <<~SQL.squish,
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_fragment_768_l2
      ON content_embeddings
      USING hnsw ((embedding::vector(768)) vector_l2_ops)
      WHERE embeddable_type = 'Fragment' AND embedding_dims = 768 AND indexed
    SQL
    'idx_ce_fragment_1024_l2' => <<~SQL.squish,
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_fragment_1024_l2
      ON content_embeddings
      USING hnsw ((embedding::vector(1024)) vector_l2_ops)
      WHERE embeddable_type = 'Fragment' AND embedding_dims = 1024 AND indexed
    SQL
    'idx_ce_code_symbol_768_cos' => <<~SQL.squish,
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_code_symbol_768_cos
      ON content_embeddings
      USING hnsw ((embedding::vector(768)) vector_cosine_ops)
      WHERE embeddable_type = 'CodeSymbol' AND embedding_dims = 768 AND indexed
    SQL
    'idx_ce_code_symbol_1024_cos' => <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_code_symbol_1024_cos
      ON content_embeddings
      USING hnsw ((embedding::vector(1024)) vector_cosine_ops)
      WHERE embeddable_type = 'CodeSymbol' AND embedding_dims = 1024 AND indexed
    SQL
  }.freeze

  def up
    execute("SET maintenance_work_mem = #{quote(MAINTENANCE_WORK_MEM)}")

    INDEXES.each do |name, ddl|
      # a failed CONCURRENTLY build leaves an INVALID index that IF NOT EXISTS
      # would silently keep — drop it so the re-run actually rebuilds
      drop_if_invalid(name)
      execute(ddl)
    end
  ensure
    # don't leak the elevated setting into whatever migration runs next on this
    # connection
    execute('RESET maintenance_work_mem')
  end

  def down
    INDEXES.each_key do |name|
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end
  end

  private

  def drop_if_invalid(name)
    invalid = select_value(<<~SQL.squish)
      SELECT NOT i.indisvalid FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = '#{name}'
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}") if invalid
  end
end
