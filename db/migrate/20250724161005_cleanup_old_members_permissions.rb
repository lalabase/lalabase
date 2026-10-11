class CleanupOldMembersPermissions < ActiveRecord::Migration[8.0]
  def up
    # Remove all old global members permissions, if they exist
    ActsAsTenant.without_tenant do
      old_permissions = Permission.where(
        category: 'projects',
        action: ['read_access_members_all_projects', 'write_access_members_all_projects', 'change_project_members']
      )
      
      if old_permissions.any?
        count = old_permissions.count
        old_permissions.destroy_all
        puts "\e[33m✅ Removed #{count} old global members permissions\e[0m"
      else
        puts "\e[32m✅ No old global members permissions to clean up\e[0m"
      end
    end
  end
  
  def down
    # Nothing to do - we do not want to restore the old permissions
  end
end
