class RemoveTimeSessionsAccessFromProjectPermissions < ActiveRecord::Migration[8.0]
  def change
    remove_column :project_permissions, :time_sessions_access, :integer
  end
end
