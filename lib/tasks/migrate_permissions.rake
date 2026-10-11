# frozen_string_literal: true

namespace :permissions do
  desc 'Migrates old global permissions to new fine-grained permissions'
  task migrate_to_granular: :environment do
    puts 'Starting migration of permissions to fine-grained permissions...'

    # Area names used in the new permissions
    areas = %w[chats notes tickets documents time_tracking]

    # Find all roles with read or write access to all projects
    Permission.where(category: 'projects', action: 'read_access_all_projects', allowed: true).each do |permission|
      puts "Migrating read permissions for role: #{permission.role.title}"

      # For each role with read_access_all_projects we create area-specific read permissions
      areas.each do |area|
        action = "read_access_#{area}_all_projects"

        # Create or update the permission
        perm = Permission.find_or_initialize_by(role: permission.role, category: 'projects', action: action)
        next if perm.allowed

        perm.allowed = true
        perm.save!
        puts "  - #{action} created"
      end
    end

    # Find all roles with write access to all projects
    Permission.where(category: 'projects', action: 'write_access_all_projects', allowed: true).each do |permission|
      puts "Migrating write permissions for role: #{permission.role.title}"

      # For each role with write_access_all_projects we create area-specific write permissions
      areas.each do |area|
        read_action = "read_access_#{area}_all_projects"
        write_action = "write_access_#{area}_all_projects"

        # Create or update read permissions (write permission implies read permission)
        read_perm = Permission.find_or_initialize_by(role: permission.role, category: 'projects', action: read_action)
        unless read_perm.allowed
          read_perm.allowed = true
          read_perm.save!
          puts "  - #{read_action} created"
        end

        # Create or update write permissions
        write_perm = Permission.find_or_initialize_by(role: permission.role, category: 'projects', action: write_action)
        next if write_perm.allowed

        write_perm.allowed = true
        write_perm.save!
        puts "  - #{write_action} created"
      end
    end

    puts 'Migration complete!'
  end
end
