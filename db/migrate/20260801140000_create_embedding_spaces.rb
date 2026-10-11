# frozen_string_literal: true

# Embedding v2 PR 6a (doc/embedding_v2_pr6_retention_plan.md §4.1): one row per
# vector space an organisation HOLDS — the triple plus a snapshot of the
# credentials needed to serve it.
#
# Why a snapshot and not just the triple (review blocker B2, main plan §5.3): the
# org's embedding_* BYOK columns are single-valued. The moment an admin points them
# at the target endpoint, the still-ACTIVE old space loses its credentials — needed
# both for its query embedding (B1) and for the roll-back delta reindex. A roll-back
# is an incident situation, the worst possible moment to re-enter access tokens.
class CreateEmbeddingSpaces < ActiveRecord::Migration[8.0]
  def change
    create_table :embedding_spaces, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid    :organisation_id,    null: false   # tenant scope + FK
      t.string  :embedding_provider, null: false   # routing key ('openai', 'openai_compatible', 'google')
      t.string  :embedding_model,    null: false
      t.integer :embedding_dims,     null: false
      # Credential snapshot. All three NULL = "resolve the system AiCredential"
      # (the org had no BYOK setup for this space) — deliberately NOT a copy of the
      # system credential, so its rotation keeps applying to every space that hangs
      # off it.
      t.string  :api_base
      t.text    :access_token # encrypts (EmbeddingSpace)
      t.string  :organization_id
      t.timestamps
    end

    # One space per org per triple. Token rotation to the SAME triple refreshes this
    # row rather than creating a second space — a rotated token does not make the
    # stored vectors incompatible. The leftmost prefix also serves plain
    # organisation_id lookups (tenant scope), so no separate index for those
    # (reference_migration_rules: leftmost prefix).
    add_index :embedding_spaces,
              %i[organisation_id embedding_provider embedding_model embedding_dims],
              unique: true, name: 'idx_embedding_spaces_unique_triple'

    # Same deliberate deviation from the house NO-ACTION convention as
    # content_embeddings (PR 2): a space describes DERIVED data and must not outlive
    # its org, not even via a callback-free parent delete_all.
    add_foreign_key :embedding_spaces, :organisations, on_delete: :cascade
  end
end
