class AddMembersAccessToProjectPermissions < ActiveRecord::Migration[8.0]
  def change
    add_column :project_permissions, :members_access, :integer, default: 0, null: false
    
    # Set members_access based on existing permissions
    ActsAsTenant.without_tenant do
      ProjectPermission.reset_column_information
      
      ProjectPermission.find_each do |permission|
        # Check whether the user has any write permission
        has_write_access = permission.tickets_access_read_write? || 
                          permission.notes_access_read_write? || 
                          permission.chats_access_read_write? || 
                          permission.documents_access_read_write? || 
                          permission.time_sessions_access_read_write?
        
        # Check whether the user has any read permission
        has_read_access = permission.tickets_access_read_only? || permission.tickets_access_read_write? ||
                         permission.notes_access_read_only? || permission.notes_access_read_write? ||
                         permission.chats_access_read_only? || permission.chats_access_read_write? ||
                         permission.documents_access_read_only? || permission.documents_access_read_write? ||
                         permission.time_sessions_access_read_only? || permission.time_sessions_access_read_write?
        
        if has_write_access
          permission.update_column(:members_access, 2) # read_write
        elsif has_read_access
          permission.update_column(:members_access, 1) # read_only
        end
      end
      
      puts "\e[33m✅ Added members_access to project_permissions table\e[0m"
      puts "\e[33m✅ Set initial members_access values based on existing permissions\e[0m"
    end
  end
end
