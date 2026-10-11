# frozen_string_literal: true

# Embedding v2 PR 6a (doc/embedding_v2_pr6_retention_plan.md §4.1): the SERVING
# pointer plus the retention budget.
#
# active_embedding_space_id is what separates CONFIGURATION (where new embeddings
# go) from SERVING (which space answers queries). Flipping it is the entire switch:
# one column, one UPDATE (Actors::FlipEmbeddingModel).
#
# embedding_retention_limit ships here but is only EVALUATED in PR 6b — a second
# migration on `organisations` for one integer column would cost more than the day
# it lies unused.
class AddActiveEmbeddingSpaceToOrganisations < ActiveRecord::Migration[8.0]
  def change
    change_table :organisations, bulk: true do |t|
      t.uuid    :active_embedding_space_id
      t.integer :embedding_retention_limit, default: 2, null: false
    end

    # ON DELETE SET NULL, deliberately NOT restrict (sheet §10, fork F3): restrict
    # would be the louder guard against a GC bug deleting the active space, but it
    # would also block org deletion — the cascade on embedding_spaces.organisation_id
    # runs straight into this pointer. The loud guard against deleting an active
    # space is a POLICY and lives in the code (retention GC, PR 6b) plus its specs,
    # which is where a policy belongs; referential integrity is not the right tool
    # for it.
    add_foreign_key :organisations, :embedding_spaces,
                    column: :active_embedding_space_id, on_delete: :nullify
  end
end
