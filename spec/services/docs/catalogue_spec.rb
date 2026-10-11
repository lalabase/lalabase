# frozen_string_literal: true

require 'rails_helper'

# What: Docs::Catalogue — the reader for the file gboyke/lalabase-documentation
#       writes, which is where the in-app help gets its pages since the
#       documentation became its own program.
#
# Why:  Not having one is the NORMAL case on a self-hosted instance and on a
#       development machine, so every reader here has to answer rather than
#       raise. And the file comes from another repository, so a shape this side
#       does not understand has to be refused loudly instead of read halfway.
RSpec.describe Docs::Catalogue do
  describe '.for' do
    it 'reads the recorded catalogue' do
      catalogue = described_class.for('de')

      # The recording is the two-page EXAMPLE the documentation repository
      # writes with `rake catalogue:example`, not the handbook: its text must
      # not live in this repository. What is asserted here is therefore the
      # reader's own work -- pages arrive, the language is the one asked for.
      expect(catalogue.pages.map(&:slug))
        .to eq(['guides/basics/erste-seite', 'guides/basics/zweite-seite'])
      expect(catalogue.locale).to eq('de')
    end

    it 'answers nil when no directory is configured' do
      without_docs_catalogue do
        expect(described_class.for('de')).to be_nil
        expect(described_class.available?).to be(false)
      end
    end

    it 'answers nil for a language that has no file' do
      write_docs_catalogue(de: [docs_catalogue_page(slug: 'guides/basics/x', title: 'X')])

      expect(described_class.for('en')).to be_nil
    end

    # Successors of two examples that left with page_loader_spec at D5, whose
    # subject stayed here. Nothing named them afterwards, which review caught.
    it 'reads an unknown language as German rather than as nothing' do
      # Docs::Contract.locale_or_default. HelpController hands it whatever the
      # address or the profile says, and neither is validated before this.
      expect(described_class.for('xx')&.locale).to eq('de')
    end

    it 'has no stamp for a language without a file, and a stamp for one with' do
      # ProductKnowledge::Sources reads this to decide whether the table is
      # still current. nil, NOT [0, 0]: a zero would drag the generation down
      # and block every later sync.
      write_docs_catalogue(de: [docs_catalogue_page(slug: 'guides/basics/x', title: 'X')])

      expect(described_class.stamp('en')).to be_nil
      expect(described_class.stamp('de')).to match([be_positive, be_positive])
    end

    it 'refuses a format it does not know, and says so in the log' do
      dir = write_docs_catalogue(de: [docs_catalogue_page(slug: 'guides/basics/x', title: 'X')])
      file = dir.join('docs_catalogue.de.json')
      file.write(file.read.sub('"format_version": 1', '"format_version": 99'))
      described_class.reset_cache!

      expect(Rails.logger).to receive(:error).with(/format_version/)
      expect(described_class.for('de')).to be_nil
    end

    it 'treats a damaged file as absent rather than raising' do
      dir = write_docs_catalogue(de: [docs_catalogue_page(slug: 'guides/basics/x', title: 'X')])
      dir.join('docs_catalogue.de.json').write('{ this is not json')
      described_class.reset_cache!

      allow(Rails.logger).to receive(:error)
      expect { described_class.for('de') }.not_to raise_error
      expect(described_class.for('de')).to be_nil
    end
  end

  describe 'caching' do
    it 'parses once while the file does not change' do
      described_class.for('de')

      expect(File).not_to receive(:read)
      2.times { described_class.for('de') }
    end

    it 'notices a new file without a restart' do
      dir = write_docs_catalogue(de: [docs_catalogue_page(slug: 'guides/basics/one', title: 'One')])
      expect(described_class.for('de').pages.map(&:slug)).to eq(['guides/basics/one'])

      # The writer renames a new file into place. mtime and size decide, the
      # same shape of stamp the page cache used before the split, so a deploy of
      # the other program is picked up on the next request with no restart here.
      sleep 0.01
      dir.join('docs_catalogue.de.json').write(
        JSON.pretty_generate(
          docs_catalogue_document('de', [docs_catalogue_page(slug: 'guides/basics/two', title: 'Two')])
        )
      )

      expect(described_class.for('de').pages.map(&:slug)).to eq(['guides/basics/two'])
    end
  end

  describe '.find_page' do
    before do
      write_docs_catalogue(
        de: [docs_catalogue_page(slug: 'guides/basics/both', title: 'Beide'),
             docs_catalogue_page(slug: 'guides/basics/de-only', title: 'Nur Deutsch')],
        en: [docs_catalogue_page(slug: 'guides/basics/both', title: 'Both', section_title: 'Basics')]
      )
    end

    it 'serves the requested language when it has the page' do
      page = described_class.find_page('en', 'guides/basics/both')

      expect(page.title).to eq('Both')
      expect(page.locale).to eq('en')
    end

    it 'falls back to German across FILES, and says which language it found' do
      page = described_class.find_page('en', 'guides/basics/de-only')

      expect(page.title).to eq('Nur Deutsch')
      # The help banner reads this: swapping the language silently would leave a
      # reader wondering why the page is in German.
      expect(page.locale).to eq('de')
    end

    it 'answers nil for a slug no language has' do
      expect(described_class.find_page('de', 'guides/nope/nope')).to be_nil
    end
  end

  describe '#search' do
    subject(:catalogue) { described_class.for('de') }

    it 'finds a page by its body, with a snippet around the hit' do
      # A word that stands in the body of both example pages and in neither
      # title, so a hit can only have come from the text.
      results = catalogue.search('Platzhaltertext')

      expect(results.map(&:slug))
        .to contain_exactly('guides/basics/erste-seite', 'guides/basics/zweite-seite')
      expect(results.first.snippet).to be_present
      expect(results.first.snippet).to include('Platzhaltertext')
    end

    it 'finds a page by its title, also when the body never says that word' do
      # Against the recorded catalogue this passed with the title clause removed,
      # because every title word appears in its own body too.
      write_docs_catalogue(
        de: [docs_catalogue_page(slug: 'guides/basics/x', title: 'Zeitzonen',
                                 text: 'Etwas ganz anderes steht hier.')]
      )

      expect(described_class.for('de').search('Zeitzonen').map(&:slug)).to eq(['guides/basics/x'])
    end

    it 'carries the section TITLE, which this app no longer computes' do
      expect(catalogue.search('Platzhaltertext').first.section).to eq('Grundlagen')
    end

    it 'stays quiet below the minimum term length' do
      expect(catalogue.search('a')).to be_empty
    end

    # Three more successors of the deleted search_spec. The search over the FILES
    # went with the documentation, but the search over the CATALOGUE is what the
    # help's own search box uses, and it lives here.
    it 'answers at exactly the minimum term length, so the gate is a floor and not a range' do
      term = 'Pl'
      expect(term.length).to eq(Docs::Contract::MIN_TERM_LENGTH)

      expect(catalogue.search(term).map(&:slug)).to include('guides/basics/erste-seite')
    end

    it 'does not care about case' do
      expect(catalogue.search('PLATZHALTERTEXT').map(&:slug))
        .to eq(catalogue.search('platzhaltertext').map(&:slug))
      expect(catalogue.search('PLATZHALTERTEXT')).not_to be_empty
    end

    it 'answers an empty list for a term no page carries, rather than raising' do
      expect(catalogue.search('nirgendsindiesemkatalog')).to eq([])
    end

    it 'has content to search, so the emptiness above means the rule and not an empty file' do
      expect(catalogue.pages).not_to be_empty
      expect(catalogue.pages.map(&:text)).to all(be_present)
    end
  end

  describe '#groups' do
    subject(:catalogue) { described_class.for('de') }

    it 'hands over the navigation ready-made and marks the current page' do
      first = catalogue.first_page
      groups = catalogue.groups(current_slug: first.slug)

      expect(groups).not_to be_empty
      expect(groups.flat_map(&:items).count(&:active)).to eq(1)
      expect(groups.first.title).to eq('Grundlagen')
    end
  end
end
