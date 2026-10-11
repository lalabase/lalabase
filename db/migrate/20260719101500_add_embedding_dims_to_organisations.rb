# frozen_string_literal: true

# Embedding v2 (doc/embedding_v2_multidim_plan.md §3.2/§4.1, PR 1): the
# embedding dimension becomes an explicit, first-class part of the vector-space
# triple (provider, model, dims) instead of being inferred from the model name.
#
# Additive + nullable + no default => no table lock, no backfill: a nil value
# keeps today's behaviour (the provider guard falls back to 1536). PR 5 opens
# the org-settings validation to the full SUPPORTED_DIMS allowlist (768/1024).
class AddEmbeddingDimsToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :embedding_dims, :integer
  end
end
