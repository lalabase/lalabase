# frozen_string_literal: true

class AddHnswIndexToCodeSymbols < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_code_symbols_signature_embedding_hnsw
      ON code_symbols
      USING hnsw (signature_embedding vector_cosine_ops)
    SQL
  end

  def down
    execute 'DROP INDEX CONCURRENTLY IF EXISTS idx_code_symbols_signature_embedding_hnsw'
  end
end
