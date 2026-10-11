# frozen_string_literal: true

namespace :i18n do
  desc 'Vergleicht Keys zwischen de.yml und en.yml — zeigt fehlende Keys pro Locale'
  task parity: :environment do
    require 'yaml'

    locale_dir = Rails.root.join('config/locales')

    # Alle YAML-Dateien nach Locale gruppieren
    locale_files = Dir[locale_dir.join('**/*.yml')].each_with_object(Hash.new { |h, k| h[k] = [] }) do |path, map|
      basename = File.basename(path, '.yml')
      # Erkennt: de.yml, foo.de.yml, foo/bar.de.yml
      locale = basename.split('.').last
      map[locale] << path if I18n.available_locales.map(&:to_s).include?(locale)
    end

    # Flache Key-Listen pro Locale extrahieren
    keys_by_locale = {}
    locale_files.each do |locale, files|
      all_keys = []
      files.each do |file|
        data = YAML.load_file(file) || {}
        all_keys.concat(flatten_keys(data[locale] || {}))
      end
      keys_by_locale[locale] = all_keys.sort.uniq
    end

    reference = 'de'
    target = 'en'

    ref_keys = keys_by_locale[reference] || []
    tgt_keys = keys_by_locale[target] || []

    missing_in_target = ref_keys - tgt_keys
    missing_in_reference = tgt_keys - ref_keys

    puts '=' * 70
    puts 'i18n Parity Report'
    puts '=' * 70
    puts
    puts "DE keys: #{ref_keys.size}"
    puts "EN keys: #{tgt_keys.size}"
    puts
    parity = ref_keys.size.positive? ? ((tgt_keys.size.to_f / ref_keys.size) * 100).round(1) : 0
    puts "Parity: #{parity}%"
    puts

    if missing_in_target.any?
      puts '-' * 70
      puts "Fehlend in EN (#{missing_in_target.size} Keys):"
      puts '-' * 70
      # Gruppiert nach Top-Level Namespace
      grouped = missing_in_target.group_by { |k| k.split('.').first(2).join('.') }
      grouped.sort.each do |ns, keys|
        puts "  #{ns} (#{keys.size})"
        keys.first(5).each { |k| puts "    - #{k}" }
        puts "    ... und #{keys.size - 5} weitere" if keys.size > 5
      end
      puts
    end

    if missing_in_reference.any?
      puts '-' * 70
      puts "Fehlend in DE (#{missing_in_reference.size} Keys):"
      puts '-' * 70
      missing_in_reference.each { |k| puts "  - #{k}" }
      puts
    end

    puts 'Alle Keys sind synchron!' if missing_in_target.empty? && missing_in_reference.empty?

    puts '=' * 70
  end
end

# Hilfsmethode: Verschachtelte Hashes in flache dot-notation Keys umwandeln
def flatten_keys(hash, prefix = '')
  hash.each_with_object([]) do |(key, value), result|
    full_key = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
    if value.is_a?(Hash)
      result.concat(flatten_keys(value, full_key))
    else
      result << full_key
    end
  end
end
