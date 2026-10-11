# frozen_string_literal: true

# Embedding v2 PR 7 — the inline vector lane is retired.
#
# Vectors lived twice since PR 2: in four inline columns (v1) and in the
# content_embeddings sidecar (v2). Reads run over the sidecar alone since PR 4b,
# writes ran "write-both" until this PR. What goes here is the v1 half: four vector
# columns, their eight provenance columns, and the two ANN indexes on them.
#
# NOT concurrent, and deliberately so. DROP COLUMN is a catalogue operation in
# PostgreSQL (attisdropped), not a table rewrite, so the ACCESS EXCLUSIVE lock is
# held for milliseconds. An index contained in a dropped column is dropped WITH it —
# a separate DROP INDEX CONCURRENTLY would be redundant, and the
# disable_ddl_transaction! it requires would cost this migration its atomicity for
# twelve statements that have every reason to succeed or fail together.
#
# Deploy note (sheet §0.9 / fork F2): running processes still ask for these columns
# until they restart. That window is accepted, not overlooked.
class DropInlineEmbeddingLane < ActiveRecord::Migration[8.0]
  # The four inline tables and their vector column. The provenance PAIR
  # (embedding_provider / embedding_model) sits on all four alike.
  INLINE_LANE = {
    code_symbols: :signature_embedding,
    fragments: :embedding,
    project_capabilities: :description_embedding,
    project_layer4_visions: :content_embedding
  }.freeze

  def up
    INLINE_LANE.each do |table, vector_column|
      # The two ANN indexes (idx_code_symbols_signature_embedding_hnsw,
      # index_fragments_on_embedding) are dropped implicitly with their column.
      remove_column table, vector_column
      remove_column table, :embedding_provider
      remove_column table, :embedding_model
    end
  end

  # Reversible in the SCHEMA sense only, and this is where that gets stated out loud
  # rather than implied: the columns come back EMPTY. Every vector this migration
  # dropped is gone from these tables for good; the only copy that survives is the
  # sidecar row in content_embeddings.
  #
  # Rolling back therefore restores the shape, not the data. Refilling it would take a
  # REVERSE backfill (content_embeddings → inline column, per record, filtered to the
  # 1536-dimensional space these vector(1536) columns can physically hold). That code
  # does not exist, is not written here, and would not be a migration if it were
  # (data migrations belong in a task — CLAUDE.md).
  #
  # Practical consequence: a rollback leaves the app fully functional, because nothing
  # has read these columns since PR 4b. It is a schema rollback, not a recovery.
  def down
    INLINE_LANE.each do |table, vector_column|
      add_column table, vector_column, :vector, limit: 1536
      add_column table, :embedding_provider, :string, null: false, default: 'openai'
      add_column table, :embedding_model, :string, null: false, default: 'text-embedding-3-small'
    end

    # Both indexes as their original migrations defined them: hnsw/cosine for symbols
    # (20260526160600), ivfflat/L2 for fragments (20250106235143). The schema.rb dump
    # loses the fragments opclass, so the original migration is the authority here.
    add_index :code_symbols, :signature_embedding,
              using: :hnsw, opclass: :vector_cosine_ops,
              name: 'idx_code_symbols_signature_embedding_hnsw'
    add_index :fragments, :embedding, using: :ivfflat, opclass: :vector_l2_ops
  end
end
