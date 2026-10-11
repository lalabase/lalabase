# frozen_string_literal: true

# Per-org BYOK columns for embeddings, mirroring the existing chat columns
# (ai_access_token / ai_provider / preferred_chat_model). An org with its own
# embedding endpoint configured routes embeddings through it; orgs that leave
# these NULL fall back to the system AiCredential (effectively OpenAI), so this
# migration changes no behaviour on its own.
#
# All columns are additive + nullable → no backfill, no long lock.
class AddEmbeddingByokToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :embedding_provider, :string
    add_column :organisations, :embedding_model, :string
    add_column :organisations, :embedding_api_base, :string
    add_column :organisations, :embedding_access_token, :text
    add_column :organisations, :embedding_organization_id, :string
  end
end
