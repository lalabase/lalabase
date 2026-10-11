class MigrateExistingTimeSessionPermissions < ActiveRecord::Migration[8.0]
  def up
    # Disable tenant checks for this migration
    ActsAsTenant.without_tenant do
      # ONLY transfer existing ProjectPermissions that have time_sessions_access
      # Do NOT create new permissions for all users!
      
      say_with_time "Migrating existing ProjectPermissions to TimeSessionPermissions" do
        count = 0
        
        # Use unscoped without includes to avoid tenant problems
        ProjectPermission.unscoped.find_each do |pp|
          # Skip if no time_sessions_access or 'no_access'
          next if pp.time_sessions_access.nil? || pp.time_sessions_access == 'no_access'

          # Make sure user and project exist
          next unless pp.user_id && pp.project_id

          # Check whether user and project really exist
          next unless User.unscoped.exists?(pp.user_id)
          next unless Project.unscoped.exists?(pp.project_id)
          
          permission = TimeSessionPermission.unscoped.find_or_initialize_by(
            user_id: pp.user_id,
            project_id: pp.project_id
          )
          
          # Transfer existing rights
          case pp.time_sessions_access
          when 'read_only'
            permission.assign_attributes(
              can_create_own: true,
              can_view_own: true,
              can_edit_own: true,
              can_delete_own: true,
              can_view_all: true,
              can_edit_all: false,
              can_delete_all: false
            )
          when 'read_write'
            permission.assign_attributes(
              can_create_own: true,
              can_view_own: true,
              can_edit_own: true,
              can_delete_own: true,
              can_view_all: true,
              can_edit_all: true,
              can_delete_all: true
            )
          else
            # Unknown value - skip
            next
          end
          
          if permission.save
            count += 1
          else
            say "Failed to save TimeSessionPermission for user_id=#{pp.user_id}, project_id=#{pp.project_id}: #{permission.errors.full_messages.join(', ')}"
          end
        end
        
        say "Migrated #{count} permissions"
        count
      end
    end
  end
  
  def down
    # Optional: reverse migration
    ActsAsTenant.without_tenant do
      TimeSessionPermission.unscoped.destroy_all
    end
  end
end