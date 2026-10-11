# frozen_string_literal: true

class CreateMeetingTicketSuggestionRuns < ActiveRecord::Migration[8.0]
  def change
    reversible do |direction|
      direction.up { execute "SET LOCAL lock_timeout = '5s'" }
      direction.down { execute "SET LOCAL lock_timeout = '5s'" }
    end
    create_table :meeting_ticket_suggestion_runs, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :meeting, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :chatpost, type: :uuid, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.uuid :project_id, null: false
      t.string :meeting_title, null: false
      t.string :project_title, null: false
      t.string :job_id, null: false, index: { unique: true }
      t.string :status, null: false, default: 'queued'
      t.text :instruction, null: false, default: ''
      t.jsonb :sources, null: false, default: {}
      t.jsonb :results, null: false, default: []
      t.boolean :result_truncated, null: false, default: false
      t.text :error, null: false, default: ''
      t.datetime :retried_at
      t.timestamps
    end
    add_index :meeting_ticket_suggestion_runs, :meeting_id, unique: true,
                                                            where: "status IN ('queued', 'running')", name: 'one_active_ticket_suggestion_run'
    add_reference :meeting_ticket_suggestions, :meeting_ticket_suggestion_run, type: :uuid,
                                                                               foreign_key: { on_delete: :nullify }, index: { name: 'index_ticket_suggestions_on_run' }
  end
end
