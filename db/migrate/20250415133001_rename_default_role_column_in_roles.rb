class RenameDefaultRoleColumnInRoles < ActiveRecord::Migration[8.0]
  def change
    rename_column :roles, :default_role, :is_default
  end
end