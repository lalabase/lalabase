# frozen_string_literal: true

# Reference — polymorphic link index for the wiki (design D3).
#
#   source (note) ──links to──▶ target (note | document)
#
# Built from the source's CANONICAL HTML (sgid attachments), not from Markdown.
# target_title_snapshot solves three things at once: tombstone label without a global
# soft-delete, backlink display without N+1 (Document#title otherwise delegates to
# current_version per row), and stable display when the target is renamed.
#
# The DB unique index is the real dedup guard (one reference per target per source).
# Backlinks run over [target_type, target_id, organisation_id].
class CreateReferences < ActiveRecord::Migration[8.0]
  def change
    create_table :references, id: :uuid do |t|
      t.uuid :organisation_id, null: false
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.string :target_title_snapshot
      t.timestamps
    end

    add_index :references, %i[target_type target_id organisation_id],
              name: "index_references_on_target_and_org"
    add_index :references, %i[source_type source_id target_type target_id],
              unique: true, name: "index_references_unique_source_target"
    add_index :references, :organisation_id
  end
end
