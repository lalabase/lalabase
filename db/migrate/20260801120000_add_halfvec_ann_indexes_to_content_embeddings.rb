# frozen_string_literal: true

# Embedding v2 PR 5b (doc/embedding_v2_pr5b_halfvec_plan.md §3.3): the 3072 lanes of the
# expression-partial HNSW indexes on the sidecar. Same metrics per type as every other
# lane — Fragment L2, CodeSymbol cosine (Embeddings::NearestNeighbors::METRICS is the
# truth per TYPE, not per dim); capabilities/visions stay exact by design.
#
# WHY halfvec here and plain vector in the twins: pgvector refuses an hnsw index above
# 2000 dimensions ("column cannot have more than 2000 dimensions for hnsw index",
# reproduced against the real DB, sheet §2.1). halfvec indexes up to 4000. The COLUMN
# stays an untyped `vector` at full precision — only the index expression casts down to
# fp16, and re-ranking reads the full-precision value with a small LIMIT.
#
# THIRD occurrence of this mechanic (twins: 20260719160000 PR 4a, 20260731120000 PR 5),
# whose comments said "unify at the third occurrence". That was re-examined here and
# deliberately NOT done — see sheet §6.2. Short version: migrations are frozen history,
# and a shared helper would let a later refactoring change what `db:migrate` builds from
# zero. The argument did not get weaker at the third repetition, it got stronger. What IS
# shared is the one thing whose divergence is dangerous rather than merely duplicated —
# the cast type, which lives in Embeddings::NearestNeighbors::INDEX_CAST_TYPE. This
# migration does NOT read that constant either (same coupling argument); the contract
# between DDL and query is enforced by content_embedding_ann_index_guard_spec, which
# fails in CI when the planner stops picking a lane.
#
# The predicate sets are EMPTY on every existing installation (no org can have been on
# 3072 before this PR), so these builds are instant; the indexes grow incrementally with
# the first reindex of a 3072 org.
#
# REQUIRES pgvector >= 0.7.0. Below that halfvec does not exist and this migration fails
# loudly — which is the correct outcome: silently skipping would leave a 3072 org with no
# index and no signal. config/initializers/pgvector_halfvec.rb warns at boot.
class AddHalfvecAnnIndexesToContentEmbeddings < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  # See the twin migrations for why a plain session-scoped SET is both possible and
  # sufficient here, and why this needs no superuser.
  MAINTENANCE_WORK_MEM = ENV.fetch('EMBEDDING_INDEX_MAINTENANCE_WORK_MEM', '2GB')

  # Fragment → halfvec_l2_ops, CodeSymbol → halfvec_cosine_ops. Spelled out rather than
  # generated: the DDL stays greppable and diffable against the twins.
  INDEXES = {
    'idx_ce_fragment_3072_l2' => <<~SQL.squish,
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_fragment_3072_l2
      ON content_embeddings
      USING hnsw ((embedding::halfvec(3072)) halfvec_l2_ops)
      WHERE embeddable_type = 'Fragment' AND embedding_dims = 3072 AND indexed
    SQL
    'idx_ce_code_symbol_3072_cos' => <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ce_code_symbol_3072_cos
      ON content_embeddings
      USING hnsw ((embedding::halfvec(3072)) halfvec_cosine_ops)
      WHERE embeddable_type = 'CodeSymbol' AND embedding_dims = 3072 AND indexed
    SQL
  }.freeze

  # Minimum pgvector version that knows the halfvec type.
  MIN_PGVECTOR = '0.7.0'

  def up
    require_halfvec_support!
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

  # Deliberately RAISES instead of skipping. Skipping would leave a database whose
  # actual schema differs from db/schema.rb — and schema.rb carries these two indexes
  # (it is dumped from a 0.7+ machine), so `db:schema:load` on an older extension fails
  # anyway. There is no variant of this migration that keeps 3072 shippable AND lets a
  # pre-0.7 installation stay consistent; the floor genuinely moves to 0.7, and the
  # self-hosting requirements say so.
  #
  # What this method buys is the difference between an opaque
  # `PG::UndefinedObject: type "halfvec" does not exist` mid-DDL and an instruction the
  # operator can act on.
  def require_halfvec_support!
    installed = select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
    return if installed.present? && Gem::Version.new(installed) >= Gem::Version.new(MIN_PGVECTOR)

    raise <<~MSG.squish
      pgvector #{installed.presence || '(not installed)'} is too old for this migration:
      the 3072-dimension ANN indexes need the halfvec type, which arrived in
      pgvector #{MIN_PGVECTOR}. Upgrade the extension on the database server, then run
      `ALTER EXTENSION vector UPDATE;` and retry the migration. See the self-hosting
      requirements docs — #{MIN_PGVECTOR} is the minimum from this release on.
    MSG
  end

  def drop_if_invalid(name)
    invalid = select_value(<<~SQL.squish)
      SELECT NOT i.indisvalid FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = '#{name}'
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}") if invalid
  end
end
