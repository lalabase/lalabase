# frozen_string_literal: true

class CreateProjectIndexes < ActiveRecord::Migration[8.0]
  def change
    create_table :project_indexes, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project_repository, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: 'pending'
      t.string :layer_4_status, null: false, default: 'pending'
      t.string :layer_3_status, null: false, default: 'pending'
      t.string :layer_1_status, null: false, default: 'pending'
      t.integer :layer_1_files_total, null: false, default: 0
      t.integer :layer_1_files_done, null: false, default: 0
      t.string :last_indexed_commit
      t.datetime :last_indexed_at
      t.text :error_message
      t.integer :index_version, null: false, default: 1

      t.timestamps
    end
  end
end
