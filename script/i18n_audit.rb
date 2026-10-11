#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

def flatten_keys(obj, prefix = nil, acc = {})
  case obj
  when Hash
    obj.each do |k, v|
      key = prefix ? "#{prefix}.#{k}" : k.to_s
      flatten_keys(v, key, acc)
    end
  else
    acc[prefix] = obj
  end
  acc
end

def load_locale(path)
  data = YAML.load_file(path)
  # top-level has language key
  lang, content = data.first
  [lang.to_s, content]
end

def diff(base_path, other_path)
  base_lang, base = load_locale(base_path)
  other_lang, other = load_locale(other_path)

  base_flat = flatten_keys(base)
  other_flat = flatten_keys(other)

  base_keys = base_flat.keys.to_set
  other_keys = other_flat.keys.to_set

  missing_in_other = base_keys - other_keys
  extra_in_other   = other_keys - base_keys

  { base_lang: base_lang, other_lang: other_lang, missing_in_other: missing_in_other.to_a.sort, extra_in_other: extra_in_other.to_a.sort }
end

de_path = File.join('config', 'locales', 'de.yml')
en_path = File.join('config', 'locales', 'en.yml')

unless File.exist?(de_path) && File.exist?(en_path)
  warn "Could not find locales: #{de_path} or #{en_path}"
  exit 1
end

report = diff(de_path, en_path)

puts "I18n audit: keys present in #{report[:base_lang]} but missing in #{report[:other_lang]} (#{report[:missing_in_other].size})"
report[:missing_in_other].each { |k| puts "  - #{k}" }

puts "\nKeys present in #{report[:other_lang]} but not in #{report[:base_lang]} (#{report[:extra_in_other].size})"
report[:extra_in_other].each { |k| puts "  + #{k}" }
