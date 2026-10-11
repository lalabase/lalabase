# frozen_string_literal: true

class CreateDocumentationSets < ActiveRecord::Migration[8.0]
  def change
    create_table :documentation_sets, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :project_repository, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      # Repo folder the docs live in. Convention default, overridable per set.
      t.string :path_prefix, null: false, default: '.lalabase/doku/'
      # Live sync state on the set itself (mirrors ProjectIndex live-state pattern).
      t.string :sync_status, null: false, default: 'never_synced'
      t.datetime :last_synced_at
      t.string :last_synced_commit
      t.timestamps
    end

    add_index :documentation_sets, %i[project_id name organisation_id],
              unique: true, name: 'idx_documentation_sets_project_name'
  end
end
