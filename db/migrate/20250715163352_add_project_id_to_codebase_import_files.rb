class AddProjectIdToCodebaseImportFiles < ActiveRecord::Migration[8.0]
  def change
    add_reference :codebase_import_files, :project, type: :uuid, null: true, foreign_key: true
    add_index :codebase_import_files, [:organisation_id, :project_id]
  end
end
