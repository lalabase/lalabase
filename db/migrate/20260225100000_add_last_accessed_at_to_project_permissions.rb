# frozen_string_literal: true

class AddLastAccessedAtToProjectPermissions < ActiveRecord::Migration[8.0]
  def change
    add_column :project_permissions, :last_accessed_at, :datetime
    add_index :project_permissions, [:user_id, :last_accessed_at],
              name: "index_project_permissions_on_user_last_accessed"
  end
end
