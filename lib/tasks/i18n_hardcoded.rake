# frozen_string_literal: true

namespace :i18n do
  desc 'Scans views, controllers and components for hardcoded German strings'
  task hardcoded: :environment do
    scan_dirs = %w[
      app/views
      app/controllers
      app/components
      app/helpers
      app/mailers
    ].map { |d| Rails.root.join(d) }

    # German words/patterns that indicate hardcoded strings
    # Only words that are unambiguous in a UI context (no variable names etc.)
    german_patterns = [
      # Flash messages & confirmations
      /(?:notice|alert|flash)\s*[:=]\s*['"][A-ZÄÖÜ]/,
      /(?:notice|alert):\s*['"][A-ZÄÖÜ]/,

      # Typical German UI strings (not in comments/t() calls)
      /['"](?:Erfolgreich|Fehler|Ungültig|Gespeichert|Gelöscht|Aktualisiert|Angelegt|Erstellt)/,
      /['"](?:Sind Sie sicher|Wirklich|Möchten Sie|Bitte bestätigen)/,
      /['"](?:Berechtigung|Zugriff|Keine Berechtigung|Nicht autorisiert)/,
      /['"](?:wurde erfolgreich|konnte nicht|ist ungültig|nicht gefunden)/,
      /['"](?:Projekt|Ticket|Dokument|Benutzer|Benachrichtigung|Einstellung)/,

      # Content tags with German strings
      /content_tag.*['"][A-ZÄÖÜ][a-zäöüß]+/,

      # Link_to / button_to with German labels
      /(?:link_to|button_to)\s+['"][A-ZÄÖÜ]/,

      # Placeholder/label in form helpers
      /placeholder:\s*['"][A-ZÄÖÜ]/,
      /label:\s*['"][A-ZÄÖÜ]/,

      # Direct HTML text in ERB (outside of tags)
      />\s*[A-ZÄÖÜ][a-zäöüß]+(?:\s+[a-zäöüßA-ZÄÖÜ]+){1,}/
    ]

    # Files that are skipped
    skip_patterns = [
      /style_guide/,
      /\.keep$/,
      /node_modules/,
      /vendor/
    ]

    extensions = %w[.erb .rb .html.erb .haml .slim]

    total_files = 0
    files_with_issues = 0
    total_hits = 0
    results = []

    scan_dirs.each do |dir|
      next unless dir.exist?

      Dir.glob(dir.join('**/*')).each do |file_path|
        next unless extensions.any? { |ext| file_path.end_with?(ext) }
        next if skip_patterns.any? { |p| file_path.match?(p) }

        total_files += 1
        content = File.read(file_path)
        lines = content.lines
        file_hits = []

        lines.each_with_index do |line, idx|
          # Skip comments
          stripped = line.strip
          next if stripped.start_with?('#', '<%#', '<!--')
          # Skip already translated strings
          next if stripped.include?('t(') || stripped.include?("t '") || stripped.include?('I18n.t')

          german_patterns.each do |pattern|
            next unless line.match?(pattern)

            file_hits << { line: idx + 1, content: stripped.truncate(120) }
            break # One hit per line is enough
          end
        end

        next unless file_hits.any?

        files_with_issues += 1
        total_hits += file_hits.size
        results << { file: file_path.sub(Rails.root.to_s + '/', ''), hits: file_hits }
      end
    end

    puts '=' * 70
    puts 'i18n Hardcoded String Report'
    puts '=' * 70
    puts
    puts "Scanned files: #{total_files}"
    puts "Files with hits: #{files_with_issues}"
    puts "Total hits: #{total_hits}"
    clean_pct = total_files.positive? ? (((total_files - files_with_issues).to_f / total_files) * 100).round(1) : 0
    puts "Clean: #{clean_pct}%"
    puts

    if results.any?
      # Grouped by directory
      grouped = results.group_by { |r| File.dirname(r[:file]).split('/').first(3).join('/') }

      grouped.sort.each do |dir, entries|
        dir_hits = entries.sum { |e| e[:hits].size }
        puts '-' * 70
        puts "#{dir} (#{entries.size} files, #{dir_hits} hits)"
        puts '-' * 70

        entries.sort_by { |e| e[:file] }.each do |entry|
          puts "  #{entry[:file]}"
          entry[:hits].first(3).each do |hit|
            puts "    L#{hit[:line]}: #{hit[:content]}"
          end
          puts "    ... +#{entry[:hits].size - 3} more" if entry[:hits].size > 3
        end
        puts
      end
    else
      puts 'No hardcoded German strings found!'
    end

    puts '=' * 70
  end
end
