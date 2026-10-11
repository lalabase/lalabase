# frozen_string_literal: true

namespace :pundit do
  desc 'Show the latest Pundit security warnings'
  task :warnings, [:lines] => :environment do |_t, args|
    lines = args[:lines]&.to_i || 50
    log_file = Rails.root.join('log', "pundit_security_#{Rails.env}.log")

    if File.exist?(log_file)
      puts "\n📋 Latest #{lines} Pundit security warnings:\n"
      puts '═' * 80
      system("tail -n #{lines} #{log_file}")
      puts '═' * 80

      # Count warnings per controller
      puts "\n📊 Summary:"
      warnings = File.readlines(log_file).select { |line| line.include?('SECURITY WARNING') }
      controller_counts = warnings.group_by { |w| w[/(\w+Controller)#/, 1] }.transform_values(&:count)
      controller_counts.sort_by { |_, count| -count }.each do |controller, count|
        puts "  • #{controller}: #{count} warnings"
      end
      puts "\n🔴 Total: #{warnings.count} warnings\n\n"
    else
      puts "❌ No Pundit security log file found: #{log_file}"
    end
  end

  desc 'Clear the Pundit security log'
  task clear_log: :environment do
    log_file = Rails.root.join('log', "pundit_security_#{Rails.env}.log")
    if File.exist?(log_file)
      File.truncate(log_file, 0)
      puts "✅ Pundit security log cleared: #{log_file}"
    else
      puts "❌ No log file found: #{log_file}"
    end
  end

  desc 'Show live updates of the Pundit warnings'
  task watch: :environment do
    log_file = Rails.root.join('log', "pundit_security_#{Rails.env}.log")

    if File.exist?(log_file)
      puts "👀 Watching Pundit security log... (Ctrl+C to quit)\n\n"
      system("tail -f #{log_file}")
    else
      puts "❌ No log file found: #{log_file}"
    end
  end
end
