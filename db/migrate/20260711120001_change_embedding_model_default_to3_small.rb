# frozen_string_literal: true

# Moves the system embedding default from text-embedding-ada-002 to
# text-embedding-3-small (~5x cheaper, slightly better MTEB, native 1536 dims —
# same vector(1536) lane, no ANN/schema rebuild).
#
# Scope is DEFAULT-ONLY on the four provenance-stamped vector tables: existing
# rows keep their materialised ada-002 stamp (their vectors really were computed
# with ada-002) and are re-stamped later by Embeddings::OrganisationReindexer.
# No data is touched here (project rule: data migrations run as a task/service).
#
# NOTE: organisations.embedding_model is deliberately NOT touched — it is nullable
# with no default (nil = "follow the system default"), and the openai provider
# reads the DEFAULT_EMBEDDING_MODEL constant, not that column. Adding a column
# default there would re-materialise a value the provider ignores and break the
# "nil = follow default" design.
class ChangeEmbeddingModelDefaultTo3Small < ActiveRecord::Migration[8.0]
  OLD_DEFAULT = 'text-embedding-ada-002'
  NEW_DEFAULT = 'text-embedding-3-small'
  TABLES = %i[fragments code_symbols project_capabilities project_layer4_visions].freeze

  def change
    TABLES.each do |table|
      change_column_default table, :embedding_model, from: OLD_DEFAULT, to: NEW_DEFAULT
    end
  end
end
