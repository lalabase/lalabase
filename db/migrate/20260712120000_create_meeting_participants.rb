# frozen_string_literal: true

# Slice 1b: structured participants for a Meeting (Gespräche). display_name is a
# snapshot (survives user deletion via on_delete: :nullify); normalized_name backs
# both the dedup unique index and the org-wide person search.
class CreateMeetingParticipants < ActiveRecord::Migration[8.0]
  def change
    create_table :meeting_participants, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      # organisation_id gets no standalone index: the composite
      # (organisation_id, normalized_name) below covers the leftmost prefix.
      t.references :organisation, type: :uuid, null: false, foreign_key: true, index: false
      # meeting_id likewise leans on the (meeting_id, normalized_name) unique index.
      t.references :meeting, type: :uuid, null: false, foreign_key: true, index: false
      # Name stays as a snapshot when the linked user is deleted.
      t.references :user, type: :uuid, null: true, foreign_key: { on_delete: :nullify }
      t.string :display_name, null: false
      t.string :normalized_name, null: false
      t.timestamps
    end

    # A person appears at most once per meeting (case/whitespace/umlaut-insensitive
    # via the normalized form).
    add_index :meeting_participants, %i[meeting_id normalized_name], unique: true
    # The same internal user must not be attached twice under different spellings.
    add_index :meeting_participants, %i[meeting_id user_id], unique: true,
                                                             where: 'user_id IS NOT NULL'
    # Read-path index (Eng-Review D10): org-wide person search (Slice 1c) and
    # participant_suggestions (Slice 1b) query by name, not by meeting — the
    # unique indexes above start with meeting_id and don't cover that direction.
    add_index :meeting_participants, %i[organisation_id normalized_name]
  end
end
