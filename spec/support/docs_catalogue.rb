# frozen_string_literal: true

# The help reads a catalogue file that another program writes
# (gboyke/lalabase-documentation). In this suite it reads one that program
# really wrote, recorded under spec/fixtures/docs_catalogue and refreshed with
# `rake catalogue:example` over there plus
# `bin/rails "docs:catalogue_fixture[<dir>]"` here.
#
# Recorded rather than rebuilt here on purpose: a catalogue this repository
# assembles itself would drift from the format the other program writes, and the
# drift would look like passing specs.
#
# It records an EXAMPLE of two invented pages, not the handbook. The recording is
# checked in, so a recording of the handbook would carry the documentation text
# into a repository that is going open source, which is the exact thing moving
# the text out was for (doc/docs_delivery_plan.md, goal 1). The rules that did
# need the real text moved to the documentation repository with it:
# `rake anchors:check` for the anchors the contextual help links to, and
# spec/content/handbook_content_spec.rb for the content rules.
# What the caller pointed at, before this file starts overwriting it. Only the
# examples tagged :real_catalogue get it back: they are measurements over the
# real handbook, and handing them the two-page example would produce a number
# about nothing. Everything else reads the recording, so that
# `REAL_CATALOGUE=1 bundle exec rspec` runs the whole suite correctly instead of
# breaking every example that names an example page.
GIVEN_DOCS_CATALOGUE_PATH = ENV.fetch('DOCS_CATALOGUE_PATH', nil)

RSpec.configure do |config|
  # Point at the recording before each example, but do NOT drop the cache here:
  # the header of every signed-in page asks whether a catalogue exists, so a
  # reset per example re-parsed the file thousands of times over a suite run
  # (which cost real minutes while the recording was the half-megabyte
  # handbook). The reset belongs where the file actually changes, which is the
  # two helpers below and the teardown.
  #
  # Switching between the two paths needs no reset either: Docs::Catalogue keys
  # its cache on the file's path, mtime and size, so a different path is a
  # different entry.
  config.before do |example|
    ENV['DOCS_CATALOGUE_PATH'] =
      if example.metadata[:real_catalogue]
        GIVEN_DOCS_CATALOGUE_PATH
      else
        Rails.root.join('spec/fixtures/docs_catalogue').to_s
      end
  end

  config.after do
    ENV.delete('DOCS_CATALOGUE_PATH')
    Docs::Catalogue.reset_cache!
  end
end

# For the cases that are NOT an error: a self-hosted instance, or a machine that
# has not fetched a catalogue.
module WithoutDocsCatalogue
  def without_docs_catalogue
    previous = ENV.fetch('DOCS_CATALOGUE_PATH', nil)
    ENV.delete('DOCS_CATALOGUE_PATH')
    Docs::Catalogue.reset_cache!
    yield
  ensure
    ENV['DOCS_CATALOGUE_PATH'] = previous
    Docs::Catalogue.reset_cache!
  end
end

RSpec.configure { |config| config.include WithoutDocsCatalogue }

# Builds a SMALL catalogue for the cases the recorded one cannot cover: a page
# that exists in one language only, or a body chosen to probe the sanitizer.
#
# ⚠️ This assembles the format rather than recording it, which is the drift risk
# the recorded fixture exists to avoid. docs_catalogue_format_spec.rb therefore
# compares what this writes against the real file, key by key.
module DocsCatalogueBuilder
  def write_docs_catalogue(pages_by_locale)
    dir = Pathname.new(Dir.mktmpdir)
    pages_by_locale.each do |locale, pages|
      dir.join("docs_catalogue.#{locale}.json").write(JSON.pretty_generate(
                                                        docs_catalogue_document(locale.to_s, pages)
                                                      ))
    end

    ENV['DOCS_CATALOGUE_PATH'] = dir.to_s
    Docs::Catalogue.reset_cache!
    @docs_catalogue_dirs = (@docs_catalogue_dirs || []) << dir
    dir
  end

  # One page, spelled out, so a caller writes only what its example is about.
  def docs_catalogue_page(slug:, title:, html: '<p>Inhalt.</p>', section: 'basics',
                          section_title: 'Grundlagen', description: nil,
                          markdown: nil, text: nil)
    { slug: slug, title: title, section: section, section_title: section_title,
      description: description, html: html,
      markdown: markdown || "# #{title}\n", text: text || 'Inhalt.' }
  end

  def docs_catalogue_document(locale, pages)
    {
      format_version: Docs::Catalogue::SUPPORTED_FORMAT,
      locale: locale,
      generated_at: Time.current.utc.iso8601,
      source_version: 'specfixture',
      groups: docs_catalogue_groups(pages),
      pages: pages
    }
  end

  def docs_catalogue_groups(pages)
    pages.group_by { |page| page[:section] }.map do |section, section_pages|
      { section: section,
        title: section_pages.first[:section_title],
        items: section_pages.map { |page| { slug: page[:slug], title: page[:title] } } }
    end
  end
end

RSpec.configure do |config|
  config.include DocsCatalogueBuilder
  config.after do
    @docs_catalogue_dirs&.each { |dir| FileUtils.remove_entry(dir) if dir.exist? }
  end
end
