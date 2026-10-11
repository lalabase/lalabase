# frozen_string_literal: true

namespace :importmap do
  desc 'Verify importmap configuration for production deployment'
  task verify_production: :environment do
    puts '🔍 Verifying Importmap Production Configuration...'

    # Skip in development
    if Rails.env.development?
      puts 'ℹ️  Skipping verification in development (uses pin_all_from)'
      next
    end

    errors = []
    warnings = []

    # Check 1: Controllers module must be pinned
    importmap_config = Rails.application.importmap.to_hash

    if importmap_config.key?('controllers')
      puts "✅ 'controllers' module is pinned"
    else
      errors << "❌ Missing pin for 'controllers' module (required by import \"controllers\")"
    end

    # Check 2: All controller files should be pinned individually
    controller_files = Dir.glob(Rails.root.join('app/javascript/controllers/**/*_controller.js'))
    controller_modules = controller_files.map do |f|
      Pathname(f).relative_path_from(Rails.root.join('app/javascript')).to_s.sub(/\.js$/, '')
    end

    missing_controllers = controller_modules.reject { |mod| importmap_config.key?(mod) }

    if missing_controllers.empty?
      puts "✅ All #{controller_modules.size} controllers are pinned"
    else
      errors << "❌ Missing controller pins: #{missing_controllers.join(', ')}"
    end

    # Check 3: No unused pins
    pinned_controllers = importmap_config.keys.select { |k| k.start_with?('controllers/') && k.end_with?('_controller') }
    unused_pins = pinned_controllers.reject do |pin|
      File.exist?(Rails.root.join("app/javascript/#{pin}.js"))
    end

    warnings << "⚠️  Unused controller pins (files don't exist): #{unused_pins.join(', ')}" unless unused_pins.empty?

    # Check 4: Asset precompilation includes controllers
    precompile_list = Rails.application.config.assets.precompile
    has_controller_pattern = precompile_list.any? do |item|
      item.is_a?(String) && item.include?('controllers/')
    end

    if has_controller_pattern
      puts '✅ Controllers are included in asset precompilation'
    else
      errors << "❌ Assets precompile list doesn't include controller pattern"
    end

    # Summary
    puts "\n📊 Summary:"
    puts "  Controllers pinned: #{controller_modules.size}"
    puts "  Import modules: #{importmap_config.keys.size}"

    # Output results
    warnings.each { |w| puts w }
    errors.each { |e| puts e }

    if errors.empty?
      puts "\n🎉 Importmap configuration is valid for production!"
      exit 0
    else
      puts "\n💥 Importmap configuration has errors that will cause production failures!"
      exit 1
    end
  end
end
