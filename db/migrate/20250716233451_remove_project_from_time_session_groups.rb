class RemoveProjectFromTimeSessionGroups < ActiveRecord::Migration[8.0]
  def change
    remove_index :time_session_groups, [:project_id, :billed]
    remove_index :time_session_groups, :project_id
    remove_foreign_key :time_session_groups, :projects
    remove_column :time_session_groups, :project_id, :uuid
  end
end
