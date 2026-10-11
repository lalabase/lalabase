#!/usr/bin/env ruby
# frozen_string_literal: true

# Find all partial files
partial_files = Dir.glob('app/views/**/_*.{erb,html.erb}').map do |file|
  Pathname.new(file).relative_path_from(Pathname.new('app/views'))
end

# Extract partial names from filenames
partials = partial_files.map do |file|
  dir = file.dirname.to_s
  basename = file.basename.to_s.gsub(/^_/, '').gsub(/\.(html\.)?erb$/, '')

  # Create possible render patterns
  patterns = []

  # Direct partial name
  patterns << basename

  # With directory prefix
  if dir != '.'
    patterns << "#{dir}/#{basename}"
    # Without organisation prefix for some paths
    patterns << dir.gsub(%r{^organisations/}, '') + "/#{basename}"
  end

  { file: file.to_s, patterns: patterns }
end

# Search for references to each partial
unused_partials = []
used_partials = []

partials.each do |partial|
  found = false

  partial[:patterns].each do |pattern|
    # Search in various file types
    search_locations = [
      'app/views/**/*.erb',
      'app/views/**/*.html.erb',
      'app/controllers/**/*.rb',
      'app/helpers/**/*.rb',
      'app/components/**/*.rb',
      'app/components/**/*.erb'
    ]

    # Different render patterns to search for
    render_patterns = [
      "render.*['\"]#{pattern}['\"]",
      "render.*partial:.*['\"]#{pattern}['\"]",
      "render.*:partial.*=>.*['\"]#{pattern}['\"]",
      "render.*'#{pattern}'",
      "render.*\"#{pattern}\"",
      "partial:.*'#{pattern}'",
      "partial:.*\"#{pattern}\""
    ]

    break if found

    search_locations.each do |location|
      break if found

      Dir.glob(location).each do |file|
        # Skip the partial file itself
        next if file.end_with?("_#{partial[:file].split('/').last}")

        content = File.read(file)

        render_patterns.each do |render_pattern|
          if content.match?(/#{render_pattern}/i)
            found = true
            break
          end
        end

        break if found
      end
    end
  end

  if found
    used_partials << partial[:file]
  else
    unused_partials << partial[:file]
  end
end

puts '=== PARTIAL ANALYSIS ==='
puts "Total partials: #{partials.length}"
puts "Used partials: #{used_partials.length}"
puts "Potentially unused partials: #{unused_partials.length}"
puts "\n=== POTENTIALLY UNUSED PARTIALS ==="

# Group by directory
grouped = unused_partials.group_by { |f| File.dirname(f) }

grouped.sort.each do |dir, files|
  puts "\n#{dir}/"
  files.sort.each do |file|
    puts "  _#{File.basename(file)}"
  end
end

puts "\n=== SUGGESTIONS ==="
puts '1. These partials might be unused, but verify manually before deleting'
puts '2. Check for dynamic renders using variables'
puts '3. Check for renders in turbo_stream.erb files'
puts '4. Some might be rendered from JavaScript or Stimulus controllers'
