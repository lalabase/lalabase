# frozen_string_literal: true

# Slice 7a: org-wide prompt library for meeting analyses (Gespräche). A prompt is
# an org asset that outlives its author (creator_id nullifies on user deletion,
# like meeting_participants.user_id). Managed inline in the analysis form (E20) —
# no dedicated settings page v1.
class CreateAnalysisPrompts < ActiveRecord::Migration[8.0]
  def change
    create_table :analysis_prompts, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      # Org asset — the author is authoring metadata, so the prompt survives the
      # user's deletion (the snapshot on each analysis keeps the title anyway).
      t.references :creator, type: :uuid, null: true,
                             foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :title, null: false
      t.text :prompt_text, null: false
      t.timestamps
    end
  end
end
