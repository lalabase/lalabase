# frozen_string_literal: true

namespace :fix do
  desc 'Set members_access based on existing permissions'
  task members_access: :environment do
    ActsAsTenant.without_tenant do
      updated_count = 0

      ProjectPermission.find_each do |permission|
        # Check whether the user has any write permission
        has_write_access = permission.tickets_access_read_write? ||
                           permission.notes_access_read_write? ||
                           permission.chats_access_read_write? ||
                           permission.documents_access_read_write?
        # time_sessions_access removed - managed via TimeSessionPermission

        # Check whether the user has any read permission
        has_read_access = permission.tickets_access_read_only? || permission.tickets_access_read_write? ||
                          permission.notes_access_read_only? || permission.notes_access_read_write? ||
                          permission.chats_access_read_only? || permission.chats_access_read_write? ||
                          permission.documents_access_read_only? || permission.documents_access_read_write?
        # time_sessions_access removed - managed via TimeSessionPermission

        if has_write_access
          permission.update_column(:members_access, 2) # read_write
          updated_count += 1
          puts "\e[32m✓ User #{permission.user.email} in project #{permission.project.name}: read_write\e[0m"
        elsif has_read_access
          permission.update_column(:members_access, 1) # read_only
          updated_count += 1
          puts "\e[33m✓ User #{permission.user.email} in project #{permission.project.name}: read_only\e[0m"
        else
          puts "\e[90m✓ User #{permission.user.email} in project #{permission.project.name}: no_access\e[0m"
        end
      end

      puts "\n\e[32m✅ Updated #{updated_count} project permissions with members_access\e[0m"
    end
  end
end
