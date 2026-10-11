# frozen_string_literal: true

# lib/tasks/importmap_verify_runtime.rake

namespace :importmap do
  desc 'Verify that every pinned controller resolves to a digested asset (runtime)'
  task verify_runtime: :environment do
    puts '🔍 Checking Importmap Controller Resolution...'
    puts '=' * 60

    h = ActionController::Base.helpers
    content = File.read(Rails.root.join('config/importmap.rb'))

    # Extract controller pins from importmap.rb
    controller_pins = content.scan(/pin\s+['"]([^'"]*controllers[^'"]*?)['"],?\s*(?:to:\s*['"]([^'"]+)['"])?/)

    bad_digests = []
    missing_files = []
    good_count = 0

    puts "Found #{controller_pins.size} controller pins to verify:\n\n"

    controller_pins.each do |logical_path, to_path|
      # Use 'to' path if specified, otherwise construct from logical path
      asset_name = to_path || "#{logical_path}.js"

      begin
        # Try to resolve the asset path
        url = h.asset_path(asset_name)

        # Check if it has a digest (hash)
        if url =~ /-[0-9a-f]{16,}\.js(\?|$)/
          puts "✅ #{logical_path} -> #{url}"
          good_count += 1
        else
          puts "❌ #{logical_path} -> #{url} (NO DIGEST)"
          bad_digests << [logical_path, asset_name, url]
        end
      rescue StandardError => e
        puts "💥 #{logical_path} -> ERROR: #{e.message}"
        missing_files << [logical_path, asset_name, e.message]
      end
    end

    puts "\n" + '=' * 60
    puts '📊 SUMMARY:'
    puts "  ✅ Controllers with digested URLs: #{good_count}"
    puts "  ❌ Controllers with fallback URLs: #{bad_digests.size}"
    puts "  💥 Controllers with errors: #{missing_files.size}"

    if bad_digests.any?
      puts "\n🚨 FALLBACK URLs (these cause 404s):"
      bad_digests.each do |logical, asset, url|
        puts "   #{logical}: #{asset} -> #{url}"
      end
    end

    if missing_files.any?
      puts "\n💥 MISSING/ERROR Controllers:"
      missing_files.each do |logical, asset, error|
        puts "   #{logical}: #{asset} -> #{error}"
      end
    end

    if bad_digests.any? || missing_files.any?
      puts "\n❌ Some controllers will cause 404 errors!"
      puts 'Fix: Ensure assets are precompiled and manifest includes all controllers'
      exit 1
    else
      puts "\n🎉 All controller imports should work perfectly!"
    end
  end
end
