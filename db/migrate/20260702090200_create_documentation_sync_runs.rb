# frozen_string_literal: true

class CreateDocumentationSyncRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :documentation_sync_runs, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :documentation_set, type: :uuid, null: false, foreign_key: true
      t.string :status, null: false
      t.string :trigger, null: false
      # DT4: one of six distinguishable sync error classes (nil on success).
      t.string :error_class
      t.text :error_message
      t.string :commit_sha
      t.integer :pages_synced, null: false, default: 0
      t.integer :pages_removed, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.uuid :triggered_by_user_id
      t.timestamps
    end

    add_index :documentation_sync_runs, %i[documentation_set_id created_at]
    add_foreign_key :documentation_sync_runs, :users,
                    column: :triggered_by_user_id, on_delete: :nullify
  end
end
