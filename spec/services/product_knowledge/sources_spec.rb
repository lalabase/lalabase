# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'fileutils'

# What:  ProductKnowledge::Sources, which of Lalabase's own texts go into the table, and the
#        cheap answers EnsureFresh asks first (stamp, generation, completeness, fingerprint).
# Type:  Service test, against a fixture docs directory and once against the real help.
# Why:   It is the fail-closed door: the self-hosting docs have not launched and must never
#        become a row. It owns the content hash and the fingerprint, and a hash that misses a
#        column is a change that silently never reaches the table. The real-help group also
#        guards what step 2 relies on: every page has a description for the contents tool.
RSpec.describe ProductKnowledge::Sources do
  describe 'over a fixture catalogue' do
    before do
      @dir = write_docs_catalogue(
        de: [docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Zeiterfassung',
                                 section: 'features', section_title: 'Funktionen',
                                 description: 'Worum es auf Zeiterfassung geht.',
                                 markdown: "# Zeiterfassung\n\nZeiten **buchen**.\n",
                                 text: 'Zeiterfassung Zeiten buchen.')],
        en: [docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Time tracking',
                                 section: 'features', section_title: 'Features',
                                 description: 'What Time tracking is about.',
                                 markdown: "# Time tracking\n\nBook **time**.\n",
                                 text: 'Time tracking Book time.')]
      )
    end

    def rewrite(locale, pages)
      @dir.join("docs_catalogue.#{locale}.json")
          .write(JSON.pretty_generate(docs_catalogue_document(locale, pages)))
      Docs::Catalogue.reset_cache!
    end

    def row_in(locale)
      described_class.rows.find { |row| row[:locale] == locale }
    end

    it 'reads every page of the catalogue, in both languages' do
      # WHICH pages are in it is decided where the catalogue is written, not
      # here: this side has no filter left, which is the point of the split.
      expect(described_class.rows.map { |row| described_class.key_of(row) }).to contain_exactly(
        ['help', 'de', 'guides/features/time-tracking'], ['help', 'en', 'guides/features/time-tracking']
      )
    end

    it 'takes the markdown, the plain text and the description straight from the catalogue' do
      row = row_in('de')

      expect(row[:body_markdown]).to include('Zeiten **buchen**.')
      expect(row[:body_text]).to include('Zeiten buchen.')
      expect(row[:body_text]).not_to include('**', '<')
      expect(row[:description]).to eq('Worum es auf Zeiterfassung geht.')
    end

    it 'takes the section label in the language of the page, already translated' do
      # This side no longer looks a section title up: the other program wrote it
      # in the language of the file it belongs to.
      expect(row_in('de')[:section]).to eq('Funktionen')
      expect(row_in('en')[:section]).to eq('Features')
    end

    it 'hashes every written column, so a change to any of them reaches the table' do
      expect(row_in('de').keys - [:content_hash]).to match_array(described_class::WRITTEN_COLUMNS)

      before_hash = row_in('de')[:content_hash]
      rewrite('de', [docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Zeiten erfassen',
                                         section: 'features', section_title: 'Funktionen')])
      expect(row_in('de')[:content_hash]).not_to eq(before_hash)
    end

    it 'keeps the first of two entries that carry the same slug' do
      rewrite('de', [docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Zeiterfassung',
                                         section: 'features', section_title: 'Funktionen'),
                     docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Zweiter Eintrag',
                                         section: 'features', section_title: 'Funktionen')])

      de_rows = described_class.rows.select { |row| row[:locale] == 'de' }
      expect(de_rows.map { |row| row[:title] }).to eq(['Zeiterfassung'])
    end

    it 'calls a source complete only when every language yields pages' do
      rows = described_class.rows

      expect(described_class.complete?(rows)).to be true
      expect(described_class.complete?(rows.reject { |row| row[:locale] == 'en' })).to be false
      expect(described_class.complete?([])).to be false
    end

    it 'is incomplete when a language has no catalogue at all' do
      # The normal state on a self-hosted instance. Incomplete means EnsureFresh
      # does not sync, so the table keeps what it has instead of being emptied.
      @dir.join('docs_catalogue.en.json').delete
      Docs::Catalogue.reset_cache!

      expect(described_class.complete?(described_class.rows)).to be false
    end

    it 'stamps each language by size and time, and takes the newest as the generation' do
      File.utime(3_000, 3_000, @dir.join('docs_catalogue.de.json'))
      File.utime(7_000, 7_000, @dir.join('docs_catalogue.en.json'))
      Docs::Catalogue.reset_cache!

      stamp = described_class.stamp
      expect(stamp.map(&:last)).to eq([3_000, 7_000])
      expect(described_class.generation(stamp)).to eq(7_000)
    end

    it 'ignores a missing language when taking the generation' do
      # A nil stamp must not drag the generation to zero: EnsureFresh would then
      # refuse every later sync as "older than what we stored".
      @dir.join('docs_catalogue.en.json').delete
      File.utime(7_000, 7_000, @dir.join('docs_catalogue.de.json'))
      Docs::Catalogue.reset_cache!

      expect(described_class.generation(described_class.stamp)).to eq(7_000)
    end

    # Deleting a page must still sync (review of #806). The generation used to fall
    # below the stored one and the sync was refused as "an older release", so the
    # deleted page stayed searchable.
    it 'lets EnsureFresh sync away a deleted page' do
      rewrite('de', [docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Zeiterfassung',
                                         section: 'features', section_title: 'Funktionen'),
                     docs_catalogue_page(slug: 'guides/features/meetings', title: 'Meetings',
                                         section: 'features', section_title: 'Funktionen')])
      File.utime(3_000, 3_000, @dir.join('docs_catalogue.de.json'))
      File.utime(3_000, 3_000, @dir.join('docs_catalogue.en.json'))
      Docs::Catalogue.reset_cache!
      ProductKnowledge::EnsureFresh.call
      # Without this the example passed with the first sync removed: an empty
      # table plus one synced page satisfies the assertion below, and the
      # deletion it claims to guard was never exercised.
      expect(ProductKnowledgeEntry.where(locale: 'de').pluck(:slug)).to include('guides/features/meetings')

      rewrite('de', [docs_catalogue_page(slug: 'guides/features/time-tracking', title: 'Zeiterfassung',
                                         section: 'features', section_title: 'Funktionen')])
      File.utime(9_000, 9_000, @dir.join('docs_catalogue.de.json'))
      Docs::Catalogue.reset_cache!
      ProductKnowledge::EnsureFresh.forget!
      ProductKnowledge::EnsureFresh.call

      expect(ProductKnowledgeEntry.where(locale: 'de').pluck(:slug)).to eq(['guides/features/time-tracking'])
    end
  end

  describe '.build_row' do
    it 'refuses a column the table does not have' do
      expect { described_class.build_row(source: 'help', colour: 'red') }.to raise_error(ArgumentError, /colour/)
    end
  end

  describe '.fingerprint' do
    it 'is equal for equal tuples in any order and differs on any change' do
      tuples = [%w[help de a h1], %w[help en a h2]]

      expect(described_class.fingerprint(tuples.reverse)).to eq(described_class.fingerprint(tuples))
      expect(described_class.fingerprint([tuples.first])).not_to eq(described_class.fingerprint(tuples))
      expect(described_class.fingerprint([%w[help de a other], tuples.last])).not_to eq(described_class.fingerprint(tuples))
    end

    it 'agrees between the source rows and the table they were synced into' do
      rows = [product_knowledge_row('a', 'Erster Text'), product_knowledge_row('a', 'First text', locale: 'en')]
      ProductKnowledge::Sync.call(rows: rows)

      table = ProductKnowledgeEntry.pluck(*described_class::KEY_COLUMNS, :content_hash)
      expect(described_class.fingerprint(table)).to eq(described_class.fingerprint(described_class.tuples(rows)))
    end
  end

  # The rules about the CONTENT of the handbook moved to
  # gboyke/lalabase-documentation (spec/content/handbook_content_spec.rb): that
  # every page has a description, that no page links where the catalogue cannot
  # follow, and that every page fits whole into what the model is handed.
  #
  # They measured the real text, and the text is not here any more. Measured
  # against this repository's fixture they would have become rules about a
  # two-page example, which is worse than not having them: they would pass.
end
