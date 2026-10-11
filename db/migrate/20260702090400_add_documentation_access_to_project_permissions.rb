# frozen_string_literal: true

class AddDocumentationAccessToProjectPermissions < ActiveRecord::Migration[8.0]
  def change
    # New per-user project access area. Default no_access: documentation is an
    # opt-in feature, nobody had access before it existed.
    add_column :project_permissions, :documentation_access, :integer, default: 0, null: false
  end
end
