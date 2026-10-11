# frozen_string_literal: true

# DEPRECATED: These rake tasks are for the old time_sessions_access system
# TimeSession permissions are now managed via the TimeSessionPermission model
#
# For new TimeSession permissions use:
# TimeSessionPermission.create!(user: user, project: project, can_view_own: true, can_create_own: true)

namespace :permissions do
  desc '[DEPRECATED] Old time session permissions fix - use TimeSessionPermission model instead'
  task fix_time_sessions: :environment do
    puts '❌ DEPRECATED: This task is obsolete.'
    puts ''
    puts 'TimeSession permissions are now managed via the TimeSessionPermission model.'
    puts ''
    puts 'Example for new permissions:'
    puts 'TimeSessionPermission.create!('
    puts '  user: user,'
    puts '  project: project,'
    puts '  can_view_own: true,'
    puts '  can_create_own: true,'
    puts '  can_edit_own: true'
    puts ')'
    puts ''
    puts 'Migration has already been performed. The old project_permissions.time_sessions_access column was removed.'
  end

  desc '[DEPRECATED] Check project permissions - use TimeSessionPermission model instead'
  task :check_project, [:project_id] => :environment do |_t, args|
    project_id = args[:project_id]

    if project_id.blank?
      puts 'Usage: rake permissions:check_project[PROJECT_ID]'
      exit 1
    end

    project = Project.find(project_id)
    ActsAsTenant.current_tenant = project.organisation

    puts "=== TimeSession Permissions for '#{project.name}' (New System) ==="
    puts ''

    User.active.each do |user|
      permissions = TimeSessionPermission.where(user: user, project: project)

      if permissions.exists?
        permissions.each do |perm|
          puts "✅ #{user.email} - #{user.full_name}"
          puts "   can_view_own: #{perm.can_view_own}"
          puts "   can_view_all: #{perm.can_view_all}"
          puts "   can_create_own: #{perm.can_create_own}"
          puts "   can_edit_own: #{perm.can_edit_own}"
          puts "   can_edit_all: #{perm.can_edit_all}"
          puts ''
        end
      else
        puts "❌ #{user.email} - #{user.full_name} (no TimeSessionPermission)"
        puts ''
      end
    end
  end
end
