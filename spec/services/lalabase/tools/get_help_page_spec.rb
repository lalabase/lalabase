# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::GetHelpPage -- reads one page of Lalabase's own help by slug
#       (doc/product_knowledge_plan.md, S2).
# Type: Service spec: the text rules without a database, the table as given for the tool, the
#       real help files for the guards at the end.
# Why:  The page reaches a model, so its links have to mean something there: another help page
#       by slug (never a /hilfe link, which would open inside the chat frame), whether written
#       in Markdown or inside an HTML block; the other surface as bare text; external links as
#       written. Plus the promises of every read tool: the asker's language with the help's
#       own fallback, a cap the payload reports AND applies, "not found" as an empty success,
#       "not available" on an empty table, and a slug checked before any query.
RSpec.describe Lalabase::Tools::GetHelpPage do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user, language_preference: 'de') }
  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation) }

  def run(slug)
    described_class.execute(args: { slug: slug }, context: context)
  end

  def payload(slug)
    JSON.parse(run(slug).content)
  end

  describe 'contract metadata' do
    it 'is a read tool that needs the asker, for the language' do
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
      expect(described_class.input_schema[:required]).to eq(['slug'])
    end

    it 'tells the model what a link to another page looks like, and that texts are cut' do
      expect(described_class.description).to include(format(described_class::PAGE_REFERENCE, slug: '<slug>'))
      expect(described_class.description).to include('text_truncated')
    end
  end

  describe 'the text, link by link' do
    def text(markdown, slug: 'guides/basics/erste-seite')
      described_class.text_of(ProductKnowledgeEntry.new(slug: slug, body_markdown: markdown))
    end

    it 'names a linked help page by slug with its section, and hands out no /hilfe link' do
      expect(text('Siehe [Zweite](zweite-seite#ein-abschnitt).'))
        .to eq('Siehe Zweite (help page guides/basics/zweite-seite#ein-abschnitt).')
    end

    it 'resolves a Markdown link with a title the same way' do
      expect(text('[Zweite](zweite-seite "Zweite Seite")'))
        .to eq('Zweite (help page guides/basics/zweite-seite)')
    end

    # Four help pages link from inside HTML blocks. Left as they are, the model would call this
    # tool with "packages" and find nothing (review of the S2 PR).
    it 'resolves a link inside an HTML block, its text decoded' do
      html = '<p>siehe <a href="zweite-seite">Zweite &amp; letzte</a>.</p>'

      expect(text(html, slug: 'guides/basics/erste-seite'))
        .to eq('<p>siehe Zweite & letzte (help page guides/basics/zweite-seite).</p>')
    end

    it 'drops a link to the other surface to its text, as the renderer does' do
      expect(text('und [Docker](../../self-hosting/installation/docker-compose), mehr')).to eq('und Docker, mehr')
    end

    it 'keeps an external link, a pure anchor and an image as written' do
      markdown = '[Rails](https://rubyonrails.org) [oben](#status) ![Bild](../ticket-views/shot.png)'

      expect(text(markdown)).to eq(markdown)
    end
  end

  describe 'with the table as given', :product_knowledge_table_as_given do
    let!(:page) do
      create(:product_knowledge_entry,
             slug: 'guides/basics/erste-seite', title: 'Erste Beispielseite',
             description: 'Eine Seite ohne Inhalt.',
             body_markdown: "## Status\n\nSiehe [Zweite](zweite-seite#ein-abschnitt).")
    end

    it 'hands over the page as Markdown with its head fields and resolved links, and cites it' do
      result = run('guides/basics/erste-seite')
      data = JSON.parse(result.content)

      expect(data).to include('slug' => 'guides/basics/erste-seite', 'title' => 'Erste Beispielseite',
                              'section' => 'Grundlagen', 'description' => 'Eine Seite ohne Inhalt.',
                              'locale' => 'de', 'text_truncated' => false)
      expect(data['text']).to start_with('## Status').and include('(help page guides/basics/zweite-seite#ein-abschnitt)')
      expect(result.citations).to eq([Lalabase::Citations.help_page(page)])
    end

    # What a model may pass besides the bare slug. One example each: two tool calls in one
    # example read as an N+1 to Prosopite.
    { '/hilfe/guides/basics/erste-seite' => 'the help path', 'hilfe/guides/basics/erste-seite' => 'the help path unrooted',
      'guides/basics/erste-seite#status' => 'a section', 'guides/basics/erste-seite/' => 'a trailing slash',
      '  guides/basics/erste-seite  ' => 'spaces around it', 'Guides/Basics/Erste-Seite' => 'capitals',
      '/docs/de/guides/basics/erste-seite' => 'the canonical docs form' }.each do |raw, what|
      it "reads the page from a slug with #{what}" do
        expect(payload(raw)['slug']).to eq('guides/basics/erste-seite')
      end
    end

    it "reads the page in the asker's language" do
      create(:product_knowledge_entry, slug: 'guides/basics/erste-seite', locale: 'en', title: 'Working with tickets')
      actor.update!(language_preference: 'en')

      expect(payload('guides/basics/erste-seite')).to include('title' => 'Working with tickets', 'locale' => 'en')
    end

    it 'falls back to German for a page without a translation, and says so in locale' do
      actor.update!(language_preference: 'en')

      expect(payload('guides/basics/erste-seite')).to include('title' => 'Erste Beispielseite', 'locale' => 'de')
    end

    it 'answers an unknown slug with an empty success, citing nothing' do
      result = run('guides/basics/nothing-here')

      expect(result).to be_success
      expect(result).to be_empty
      expect(result.content).to include('No help page found')
      expect(result.citations).to eq([])
    end

    it 'refuses a slug that cannot name a page, before any query' do
      expect(ProductKnowledge::Search).not_to receive(:new)

      expect(run("guides/../../etc'").error).to eq('invalid slug format')
      expect(run('').error).to eq('slug is required')
    end

    # The boundary in all three positions. One example each, because two tool calls in one
    # example read as an N+1 to Prosopite. The text itself is checked too: a payload that only
    # SAID it was cut would hand the model the whole page.
    { -1 => false, 0 => false, 1 => true }.each do |offset, truncated|
      it "reports and makes #{truncated ? 'a cut' : 'no cut'} for a text #{offset} from the limit" do
        length = described_class::MAX_TEXT_CHARS + offset
        page.update_columns(body_markdown: 'a' * length)

        data = payload('guides/basics/erste-seite')

        expect(data['text_truncated']).to be(truncated)
        expect(data['text_length']).to eq(length)
        if truncated
          expect(data['text']).to eq(('a' * described_class::MAX_TEXT_CHARS) + described_class::TRUNCATION_MARKER)
        else
          expect(data['text']).to eq('a' * length)
        end
      end
    end
  end

  describe 'on an empty table', :product_knowledge_table_as_given do
    # A fresh install while another process still syncs: "no such page" would be false.
    it 'says the help is not available instead of "not found"' do
      result = run('guides/basics/erste-seite')

      expect(result).not_to be_success
      expect(result.error).to include('not available')
    end
  end

  # The cross-FILE fallback, which is the one link case the two-page example can
  # still exercise on its own: an English page may link to a page that is not
  # translated yet, the help serves that page from German, and the model must be
  # able to fetch it rather than read the link as bare text. This is why
  # get_help_page.rb reaches for Docs::Catalogue.find_page and not
  # for(locale)&.page.
  it 'keeps a reference when only the German catalogue has the linked page' do
    write_docs_catalogue(
      de: [docs_catalogue_page(slug: 'guides/basics/source', title: 'Quelle',
                               markdown: 'Siehe [Ziel](target).'),
           docs_catalogue_page(slug: 'guides/basics/target', title: 'Ziel')],
      en: [docs_catalogue_page(slug: 'guides/basics/source', title: 'Source',
                               markdown: 'See [target](target).')]
    )
    entry = ProductKnowledgeEntry.new(source: ProductKnowledge::Sources::HELP, locale: 'en',
                                      slug: 'guides/basics/source', title: 'Source',
                                      body_markdown: 'See [target](target).')

    expect(described_class.text_of(entry))
      .to include(format(described_class::PAGE_REFERENCE, slug: 'guides/basics/target'))
  end

  # Two rules that measured every REAL page moved to
  # gboyke/lalabase-documentation (spec/content/handbook_content_spec.rb): that
  # each page fits whole into MAX_TEXT_CHARS with its link references added, and
  # that every link resolves to a page that exists. The pages are there now; here
  # they would measure a two-page example and pass.
  #
  # The third rule, 'leaves no link to a docs page unresolved', could NOT move:
  # it measured the conversion, and the conversion is this repository's code. Its
  # replacement over there pins the link FORMS instead, so a form nobody converts
  # turns that spec red and names the page. Both repositories therefore hold a
  # list of the same three forms -- here PAGE_LINK and HTML_LINK in
  # get_help_page.rb, there `link_forms` in handbook_content_spec.rb -- and a
  # fourth form has to be added in both.
  #
  # What stays here is the mechanism: that the cut happens at the limit, that it
  # is reported, how a link is turned into a reference, and the fallback above.
end
