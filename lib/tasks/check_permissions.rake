# frozen_string_literal: true

namespace :check do
  desc 'Check for old members permissions'
  task permissions: :environment do
    ActsAsTenant.without_tenant do
      puts "\n\e[36m=== Checking for old members permissions ===\e[0m\n"

      # Suche nach den alten globalen members permissions
      old_permissions = Permission.where(
        category: 'projects',
        action: %w[read_access_members_all_projects write_access_members_all_projects change_project_members]
      )

      if old_permissions.any?
        puts "\e[31m❌ Found #{old_permissions.count} old members permissions:\e[0m"
        old_permissions.each do |perm|
          puts "   - Role: #{perm.role.title}, Action: #{perm.action}, Allowed: #{perm.allowed}"
        end

        puts "\n\e[33m💡 To remove these old permissions, run: rails cleanup:old_members_permissions\e[0m"
      else
        puts "\e[32m✅ No old members permissions found\e[0m"
      end

      # Zeige aktuelle project permissions
      puts "\n\e[36m=== Current valid permissions for projects ===\e[0m"
      valid_actions = Permission::CATEGORIES[:projects]
      puts "Valid actions: #{valid_actions.join(', ')}"
    end
  end
end
