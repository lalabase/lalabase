# frozen_string_literal: true

module Changelog
  class EntryLoader
    Entry = Struct.new(:slug, :title, :date, :images, :body, :body_html, keyword_init: true)

    CHANGELOG_DIR = Rails.root.join('app/changelog')
    FRONTMATTER_REGEX = /\A---\s*\n(.+?)\n---\s*\n(.*)/m

    def self.call
      new.call
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: 1.hour) { load_entries }
    end

    private

    def load_entries
      return [] unless CHANGELOG_DIR.exist?

      Dir.glob(CHANGELOG_DIR.join('*.md')).filter_map { |path| parse_entry(path) }
         .sort_by(&:date)
         .reverse
    end

    def parse_entry(path)
      content = File.read(path)
      match = content.match(FRONTMATTER_REGEX)
      return unless match

      frontmatter = YAML.safe_load(match[1], permitted_classes: [Date])
      body = match[2].strip

      Entry.new(
        slug: File.basename(path, '.md'),
        title: frontmatter['title'],
        date: frontmatter['date'].is_a?(Date) ? frontmatter['date'] : Date.parse(frontmatter['date'].to_s),
        images: Array(frontmatter['images']),
        body: body,
        body_html: render_markdown(body)
      )
    rescue StandardError => e
      Rails.logger.warn("Changelog: Failed to parse #{path}: #{e.message}")
      nil
    end

    def render_markdown(text)
      return '' if text.blank?

      renderer = Redcarpet::Render::HTML.new(hard_wrap: true, link_attributes: { target: '_blank' })
      markdown = Redcarpet::Markdown.new(renderer, autolink: true, tables: true, fenced_code_blocks: true, strikethrough: true)
      markdown.render(text)
    end

    def cache_key
      return 'changelog/entries/empty' unless CHANGELOG_DIR.exist?

      files = Dir.glob(CHANGELOG_DIR.join('*.md'))
      max_mtime = files.map { |f| File.mtime(f).to_i }.max || 0
      "changelog/entries/#{files.size}-#{max_mtime}"
    end
  end
end
