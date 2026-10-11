# frozen_string_literal: true

# Provenance columns for fragment embeddings, closing the one gap among the four
# embedded tables (code_symbols / project_capabilities / project_layer4_visions
# already carry these; fragments did not). They record which provider+model
# produced each vector, so a later provider/model switch can detect a mixed
# vector space and re-index only the stale rows.
#
# Existing fragment rows were all produced by OpenAI text-embedding-ada-002, so
# the NOT NULL defaults are factually correct → no backfill, no long lock.
class AddEmbeddingProvenanceToFragments < ActiveRecord::Migration[8.0]
  def change
    add_column :fragments, :embedding_provider, :string, null: false, default: 'openai'
    add_column :fragments, :embedding_model, :string, null: false, default: 'text-embedding-ada-002'
  end
end
