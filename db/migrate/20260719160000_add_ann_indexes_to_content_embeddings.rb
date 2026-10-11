# frozen_string_literal: true

# Embedding v2 PR 4a (doc/embedding_v2_pr4a_ann_indexes_plan.md): expression-partial
# HNSW indexes on the sidecar, 1536 lane only (768/1024 = PR 5, 3072 gated on
# pgvector >= 0.7.0). Reads stay inline until PR 4b — these indexes are built here
# but not queried yet. Only Fragment (L2) + CodeSymbol (cosine) get ANN indexes;
# capabilities/visions are small and stay exact (main plan §3.4).
#
# TWIN of db/migrate/20260731120000_add_multidim_ann_indexes_to_content_embeddings.rb
# (PR 5, the 768/1024 lanes): the mechanics below are DELIBERATELY duplicated there
# instead of extracted into a shared helper — migrations are frozen history, and a
# helper would couple this file to future refactorings. Unify at the third
# occurrence (PR 5b / halfvec); keep both in sync until then.
class AddAnnIndexesToContentEmbeddings < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  # HNSW assembles its graph in maintenance_work_mem; once the table has grown past
  # what the server default (64 MB here) holds, the build spills to disk and a
  # CONCURRENTLY run crawls. A plain SET (not SET LOCAL) is session-scoped and
  # therefore covers both builds below — possible precisely because
  # disable_ddl_transaction! leaves us in our own untransacted migration session.
  # maintenance_work_mem is USERSET, so this needs neither superuser nor a
  # postgresql.conf change. Override downwards on a memory-tight box.
  MAINTENANCE_WORK_MEM = ENV.fetch('EMBEDDING_INDEX_MAINTENANCE_WORK_MEM', '2GB')

  INDEXES = {
    'idx_ce_fragment_1536_l2' => <<~SQL.squish,
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_fragment_1536_l2
      ON content_embeddings
      USING hnsw ((embedding::vector(1536)) vector_l2_ops)
      WHERE embeddable_type = 'Fragment' AND embedding_dims = 1536 AND indexed
    SQL
    'idx_ce_code_symbol_1536_cos' => <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_code_symbol_1536_cos
      ON content_embeddings
      USING hnsw ((embedding::vector(1536)) vector_cosine_ops)
      WHERE embeddable_type = 'CodeSymbol' AND embedding_dims = 1536 AND indexed
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
