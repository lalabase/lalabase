# frozen_string_literal: true

# One row per bulk change of tickets (doc/ticket_bulk_edit_plan.md, D8): what
# was changed (changes), what happened per ticket with the previous values
# (results), and whether the run was undone. "Rückgängig" reads the previous
# values from here, the result line reads the partial results from here.
class CreateTicketBulkRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :ticket_bulk_runs, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      # The runner, kept as long as the account exists: a deleted user leaves
      # the run (audit) without a runner, as activities keep their rows.
      t.references :user, type: :uuid, null: true, foreign_key: { on_delete: :nullify }
      t.references :undo_of, type: :uuid, null: true, foreign_key: { to_table: :ticket_bulk_runs }
      # Not `changes`: that is ActiveRecord's own (dirty tracking).
      t.jsonb :change_list, null: false, default: []
      t.jsonb :results, null: false, default: {}
      t.integer :changed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.datetime :undone_at
      t.timestamps
    end
  end
end
