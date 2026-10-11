# frozen_string_literal: true

# NoteVersion — version history + diff basis per note.
#
# Semantics (design D4): EVERY save stores the NEW state; the backfill creates v0
# from the original Trix HTML. Dedup is done in the Note callback (no version on a
# no-op). Invariant: current note == latest version.
#
# html_body = snapshot of the canonical ActionText HTML, markdown_body = derived
# (same serializer as live). Both self-contained for restore/diff.
#
# note_id index deliberately NOT separate (leftmost-prefix rule): the composite
# [note_id, created_at] covers lookups by note_id AND the history ordering.
class CreateNoteVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :note_versions, id: :uuid do |t|
      t.references :note, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :organisation_id, null: false
      t.text :html_body
      t.text :markdown_body
      t.string :content_hash, null: false
      t.uuid :author_id
      t.timestamps
    end

    add_index :note_versions, %i[note_id created_at]
    add_index :note_versions, :organisation_id
    add_foreign_key :note_versions, :users, column: :author_id
  end
end
