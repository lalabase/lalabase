class AddArchiveFieldsToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :archived_at, :datetime, null: true
    add_column :projects, :archived_by_id, :uuid, null: true
    add_index :projects, :archived_at
    add_foreign_key :projects, :users, column: :archived_by_id
  end
end
