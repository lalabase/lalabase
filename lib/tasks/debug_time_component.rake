# frozen_string_literal: true

# lib/tasks/debug_time_component.rake

namespace :debug do
  # Diagnostic probe for the time_sessions area gate. Prints ProjectPolicy#area_access?
  # for a concrete non-admin user, plus their TimeSessionPermission rows — the combination
  # a guard spec run as admin cannot show, because area_access? returns early for admins.
  desc 'Debug time_sessions permissions for a user/project'
  task :time_component, %i[user_id project_id] => :environment do |_t, args|
    user_id = args[:user_id]
    project_id = args[:project_id]

    unless user_id && project_id
      puts 'Usage: rake debug:time_component[user_id,project_id]'
      exit 1
    end

    user = User.find(user_id)
    project = Project.find(project_id)

    puts '=== time_sessions permission debug ==='
    puts "User: #{user.id} (#{user.email})"
    puts "Project: #{project.id} (#{project.name})"
    puts "Organisation: #{project.organisation.id} (#{project.organisation.name})"
    puts

    project_policy = ProjectPolicy.new(user, project)
    can_read = project_policy.area_access?(:time_sessions, :read)
    can_write = project_policy.area_access?(:time_sessions, :write)
    puts "can read time_sessions?: #{can_read}"
    puts "can write time_sessions?: #{can_write}"
    puts "overall access?: #{can_read || can_write}"

    puts "\nTime Session Permissions for this user:"
    user.time_session_permissions.each do |perm|
      puts "  Project: #{perm.project.name} (ID: #{perm.project.id})"
      puts "    can_view_own: #{perm.can_view_own}"
      puts "    can_view_all: #{perm.can_view_all}"
      puts
    end

    puts 'Time Sessions in this project:'
    project.time_sessions.each do |session|
      puts "  Session ID: #{session.id}, Creator: #{session.creator.email}, Duration: #{session.duration}min"
    end
  end
end
