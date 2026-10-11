# frozen_string_literal: true

# Meetings (Gespräche) — a project's own work object for conversation/meeting
# transcripts, distinct from knowledge notes. Slice 1a foundation: the table
# plus the new :meetings project-permission column. See doc/gespraeche_plan.md §3.
#
# Deliberately NOT created here: meeting_participants (Slice 1b),
# time_sessions.meeting_id (Slice 2), summary/embedding-flag columns (Slice 4/6).
class CreateMeetings < ActiveRecord::Migration[8.0]
  def change
    create_table :meetings, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :title, null: false
      t.datetime :occurred_at, null: false
      # "Länge" in the header; optional (plan §3).
      t.integer :duration_minutes
      # notes = curated plaintext, transcript = verbatim paste — BOTH optional
      # (a meeting may be a pure time/context anchor). plain_text_version is the
      # pipeline/PgSearch contract column (concatenation of both, see Meeting model).
      t.text :notes
      t.text :transcript
      t.text :plain_text_version
      # Raw transcripts are PII-heavy: indexing is a deliberate per-meeting act,
      # so embeddings default OFF (plan decision 4). No UI toggle until Slice 6.
      t.boolean :create_embeddings, null: false, default: false

      # project_id is covered by the composite (project_id, occurred_at) index
      # below (leftmost-prefix), so skip the redundant single-column index here.
      t.references :project, type: :uuid, null: false, index: false, foreign_key: true
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :creator, type: :uuid, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    # Chronological list per project (occurred_at desc) — the master list query.
    add_index :meetings, %i[project_id occurred_at]

    # New project-permission area :meetings (enum-int, default 0 = no access),
    # mirroring notes_access / times_access. See §4 point 1.
    add_column :project_permissions, :meetings_access, :integer, null: false, default: 0
  end
end
