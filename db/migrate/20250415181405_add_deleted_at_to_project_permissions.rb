class AddDeletedAtToProjectPermissions < ActiveRecord::Migration[8.0]
  def change
    add_column :project_permissions, :deleted_at, :datetime
  end
end
