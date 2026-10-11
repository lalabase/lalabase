class AddIndexToProjectPermissionsDeletedAt < ActiveRecord::Migration[8.0]
  def change
    add_index :project_permissions, :deleted_at
  end
end
