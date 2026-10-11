# frozen_string_literal: true

require 'rails_helper'

# What:  ProductKnowledge::Search, the one reader of Lalabase's own texts.
# Type:  Service test against the real table; EnsureFresh stubbed (table as given) except in
#        the last group, which runs over the real help files.
# Why:   The point of the table is a better search than the substring loop over the files:
#        stems, prefixes, stop words dropped, terms that are not neighbours, a whole question
#        that still finds its page, a ranking, and the literal matches stemming misses. Each
#        is a decision in SQL that a plain "finds something" test would not pin. Plus the
#        promises around it: one language per answer, the help by default, and no input that
#        can break the tsquery syntax.
RSpec.describe ProductKnowledge::Search do
  subject(:search) { described_class.new(locale: 'de') }

  def entry(title:, body:, locale: 'de', slug: nil, description: nil, source: nil)
    attributes = { title: title, body_text: body, locale: locale, description: description,
                   slug: slug || "guides/test/#{title.parameterize}" }
    attributes[:source] = source if source
    create(:product_knowledge_entry, **attributes)
  end

  it 'knows a text search configuration for exactly the languages the help has' do
    expect(described_class::CONFIGS.keys).to match_array(Docs::Contract::LOCALES)
  end

  # The table of contents for the assistant's help_contents (doc/product_knowledge_plan.md, D7).
  describe '#contents', :product_knowledge_table_as_given do
    it 'lists every page of the language whatever the limit, by section and title, without text' do
      create(:product_knowledge_entry, slug: 'guides/b/zwei', title: 'Zwei', section: 'B')
      create(:product_knowledge_entry, slug: 'guides/a/zwei', title: 'Zwei', section: 'A')
      create(:product_knowledge_entry, slug: 'guides/a/eins', title: 'Eins', section: 'A')
      create(:product_knowledge_entry, slug: 'guides/a/eins', title: 'One', section: 'A', locale: 'en')

      contents = described_class.new(locale: 'de', limit: 1).contents

      expect(contents.map(&:slug)).to eq(%w[guides/a/eins guides/a/zwei guides/b/zwei])
      expect(contents.map(&:snippet).uniq).to eq([''])
    end

    it 'reads only the sources it was given' do
      create(:product_knowledge_entry, slug: 'guides/a/eins', title: 'Eins')

      expect(described_class.new(locale: 'de', sources: ['news']).contents).to eq([])
    end

    # The rule of #find, for a list: a page the translators have not reached stays discoverable.
    it 'brings a page without a translation in German, marked by its locale' do
      create(:product_knowledge_entry, slug: 'guides/a/eins', title: 'Eins', section: 'A')
      create(:product_knowledge_entry, slug: 'guides/a/eins', title: 'One', section: 'A', locale: 'en')
      create(:product_knowledge_entry, slug: 'guides/a/zwei', title: 'Zwei', section: 'A')

      contents = described_class.new(locale: 'en').contents

      expect(contents.map { |hit| [hit.slug, hit.locale, hit.title] })
        .to eq([%w[guides/a/eins en One], %w[guides/a/zwei de Zwei]])
    end
  end

  # What lets a tool tell "not there yet" from "no such page" (review of the S2 PR).
  describe '#available?', :product_knowledge_table_as_given do
    it 'says whether the table holds anything of its sources at all' do
      expect(search.available?).to be false

      create(:product_knowledge_entry, locale: 'en')

      expect(search.available?).to be true
      expect(described_class.new(locale: 'de', sources: ['news']).available?).to be false
    end
  end

  describe 'with the table as given', :product_knowledge_table_as_given do
    it 'finds a word by its stem, in both directions' do
      entry(title: 'Zeit buchen', body: 'So geht es.')
      entry(title: 'Zeiten erfassen', body: 'So geht es.')

      expect(search.query('Zeiten').map(&:title)).to contain_exactly('Zeit buchen', 'Zeiten erfassen')
      expect(search.query('Zeit').map(&:title)).to contain_exactly('Zeit buchen', 'Zeiten erfassen')
    end

    # The terms already are the language's lexemes (terms_of). Sent through the dictionary a
    # second time, a stem that is itself a stop word vanished: "Einigungen" stems to "einig", a
    # German stop word, and the page saying "Einigung" was lost (review of #806). Under a UTF-8
    # ctype "Änderungen" to "ander" is the same case; the local cluster runs with C, where it is not.
    it 'does not send the terms through the dictionary a second time' do
      entry(title: 'Beschluss', body: 'Die Einigung steht fest.')

      expect(search.query('Einigungen').map(&:title)).to eq(['Beschluss'])
    end

    it 'finds the start of a compound word' do
      entry(title: 'Grundlagen', body: 'Die Zeiterfassung sitzt am Ticket.')

      expect(search.query('Zeit').map(&:title)).to eq(['Grundlagen'])
    end

    # Which pass found a hit is the difference between a page the words landed on and a page
    # that merely shares one. The help tools judge the hits by it (review of the first real run,
    # 12.09.2026), so it travels on the Hit.
    it 'says whether a hit carries every word or only some' do
      entry(title: 'Beide', body: 'Zeiten lassen sich nach dem Termin noch buchen.')
      entry(title: 'Nur eins', body: 'Zeiten ohne das zweite Wort.')

      expect(search.query('Zeit buchen').map { |hit| [hit.title, hit.match] })
        .to eq([['Beide', described_class::ALL_TERMS], ['Nur eins', described_class::SOME_TERMS]])
    end

    it 'marks a literal match as one' do
      entry(title: 'Grundlagen', body: 'Die Arbeitszeit steht am Ticket.')

      expect(search.query('rbeitsze').map { |hit| [hit.title, hit.match] })
        .to eq([['Grundlagen', described_class::LITERAL]])
    end

    it 'puts the pages with every term first, not necessarily side by side, and those with some after' do
      entry(title: 'Beide', body: 'Zeiten lassen sich nach dem Termin noch buchen.')
      entry(title: 'Nur eins', body: 'Zeiten ohne das zweite Wort.')
      entry(title: 'Keins', body: 'Ganz etwas anderes.')

      expect(search.query('Zeit buchen').map(&:title)).to eq(['Beide', 'Nur eins'])
    end

    # The words that matter come after eight others here. Cut before the stop words are gone,
    # the query would keep "Wie kann ich als Admin in der Organisation" and find only Farben.
    it 'drops the stop words before it counts terms, and settles for some terms in a whole question' do
      entry(title: 'Mitglieder einladen', body: 'So nimmst du Mitglieder in dein Projekt auf.')
      entry(title: 'Farben', body: 'Eine Farbe je Organisation.')

      hits = search.query('Wie kann ich als Admin in der Organisation schnell ein neues Mitglied einladen?')
      expect(hits.first&.title).to eq('Mitglieder einladen')
    end

    it 'ranks a hit in the title above the description above the text' do
      entry(title: 'Etwas anderes', body: 'Hier geht es um Meetings.')
      entry(title: 'Meetings', body: 'Hier geht es um etwas anderes.')
      entry(title: 'Anders', description: 'Alles über Meetings', body: 'Noch etwas.')

      expect(search.query('Meeting').map(&:title)).to eq(['Meetings', 'Anders', 'Etwas anderes'])
    end

    # The case where the two Postgres rank functions disagree (measured with psql): both
    # words five times, far apart, against both words once, side by side. ts_rank puts the
    # scattered page first, ts_rank_cd the one that says exactly this. The search promises
    # the second.
    it 'ranks the terms standing together above the same terms scattered, however often' do
      filler = 'Füllwort ' * 12
      entry(title: 'Verstreut', body: "Zeit. #{filler}Buchen. #{filler}" * 5)
      entry(title: 'Beisammen', body: "So kannst du Zeit buchen. #{'Füllwort ' * 40}")

      expect(search.query('Zeit buchen').map(&:title)).to eq(%w[Beisammen Verstreut])
    end

    it 'appends the literal matches stemming misses after the ranked hits' do
      entry(title: 'Zeiten erfassen', body: 'So geht es.')
      entry(title: 'Arbeitsschutz', body: 'Die Arbeitszeit endet um fünf.')

      expect(search.query('Zeit').map(&:title)).to eq(['Zeiten erfassen', 'Arbeitsschutz'])
    end

    it 'answers in the language it was asked in only' do
      entry(title: 'Zeiterfassung', body: 'Deutsch.', slug: 'guides/features/time-tracking')
      entry(title: 'Time tracking', body: 'Zeiterfassung in English.', locale: 'en',
            slug: 'guides/features/time-tracking')

      expect(search.query('Zeiterfassung').map(&:locale)).to eq(['de'])
      expect(described_class.new(locale: 'en').query('Zeiterfassung').map(&:locale)).to eq(['en'])
    end

    it 'falls back to a literal match when full text finds nothing' do
      entry(title: 'Eigener Schlüssel', body: 'Mit einem BYOK-Schlüssel zahlt die Organisation selbst.')

      hits = search.query('YOK')
      expect(hits.map(&:title)).to eq(['Eigener Schlüssel'])
      expect(hits.first.snippet).to include('BYOK')
    end

    it 'starts the snippet at the beginning of the text when the literal match is only in the title' do
      entry(title: 'BYOK-Schlüssel', body: 'Mit einem eigenen Schlüssel zahlt die Organisation selbst.')

      expect(search.query('YOK').first.snippet).to start_with('Mit einem eigenen')
    end

    it 'gives a plain snippet around the hit' do
      entry(title: 'Grundlagen', body: "#{'Vorher. ' * 20}Die Zeiterfassung sitzt am Ticket. #{'Nachher. ' * 20}")

      snippet = search.query('Zeiterfassung').first.snippet
      expect(snippet).to include('Zeiterfassung')
      expect(snippet).not_to include('<b>')
    end

    it 'keeps quotes, backslashes and operators inside longer terms away from the query syntax' do
      entry(title: 'Grundlagen', body: 'Text.')

      # Separate searches, not one search with an N+1: the repeated query shape is this loop,
      # so the detector is paused for it.
      Prosopite.pause do
        ["it's", "O'Brien", "''", 'a\\b', '!!', '((', 'foo)', "a'&'b", 'foo:', 'a & b', ':*x', 'x | y', '<->'].each do |input|
          expect(search.query(input)).to be_an(Array), "failed for #{input.inspect}"
        end
      end
    end

    it 'treats LIKE wildcards in the literal match as text' do
      entry(title: 'Grundlagen', body: 'Text.')

      expect(search.query('%%')).to eq([])
      expect(search.query('__')).to eq([])
    end

    it 'searches a term of exactly MIN_TERM_LENGTH characters and nothing shorter' do
      entry(title: 'Zeiten erfassen', body: 'So geht es.')

      expect('Ze'.length).to eq(described_class::MIN_TERM_LENGTH)
      expect(search.query('Ze').map(&:title)).to eq(['Zeiten erfassen'])
      expect(search.query('Z')).to eq([])
    end

    it 'reads only the sources it was given, the help by default' do
      entry(title: 'Meetings', body: 'Hilfe.')
      news = { source: 'changelog', slug: 'news/meetings', title: 'Meetings neu', body_text: 'Meetings.' }
      ProductKnowledgeEntry.insert_all([attributes_for(:product_knowledge_entry, **news)])

      expect(search.query('Meeting').map(&:source)).to eq(['help'])
      expect(search.find('news/meetings')).to be_nil
      expect(described_class.new(locale: 'de', sources: []).query('Meeting')).to eq([])
    end

    it 'stops at its limit, MAX_RESULTS by default' do
      (described_class::MAX_RESULTS + 2).times { |i| entry(title: "Meeting #{i}", body: 'Meetings.') }

      expect(search.query('Meeting').size).to eq(described_class::MAX_RESULTS)
      expect(described_class.new(locale: 'de', limit: 3).query('Meeting').size).to eq(3)
    end

    it 'treats an unknown locale as German' do
      entry(title: 'Zeiten erfassen', body: 'So geht es.')

      expect(described_class.new(locale: 'fr').query('Zeit').map(&:title)).to eq(['Zeiten erfassen'])
    end

    describe '#find' do
      it 'returns the page in the asked language' do
        entry(title: 'Zeiterfassung', body: 'Deutsch.', slug: 'guides/features/time-tracking')
        english = entry(title: 'Time tracking', body: 'English.', locale: 'en', slug: 'guides/features/time-tracking')

        expect(described_class.new(locale: 'en').find('guides/features/time-tracking')).to eq(english)
      end

      it 'falls back to the German page when there is no translation yet' do
        german = entry(title: 'Zeiterfassung', body: 'Deutsch.', slug: 'guides/features/time-tracking')

        expect(described_class.new(locale: 'en').find('guides/features/time-tracking')).to eq(german)
      end

      it 'returns nil for a page that does not exist' do
        expect(search.find('guides/nowhere/nothing')).to be_nil
      end
    end
  end

  # What this describe used to hold, and what became of it: three of its examples
  # ranked real handbook pages for real questions ("Zeit buchen" must bring the
  # time tracking page first; an invitation question must bring the invitation
  # page, even with a separable verb). The handbook is not in this repository any
  # more, and the recorded catalogue is a two-page example, so those three would
  # now be rules about invented text -- they would pass, which is worse than not
  # having them.
  #
  # They did not move unchanged, they were WEAKENED to a floor, and that is worth
  # stating plainly: question_catalogue_spec.rb asks the same two questions among
  # twenty and requires 17 of the 20 to land in the first three. So the
  # invitation question may now be missed entirely -- its own comment names the
  # separable verb as one of the three misses -- and "time tracking FIRST for
  # 'Zeit buchen'" became "somewhere in the first three". What is gained is a
  # number over twenty real questions instead of three hand-picked ones. It is
  # tagged :real_catalogue and needs a catalogue generated in
  # gboyke/lalabase-documentation (see spec/rails_helper.rb).
  #
  # What stays here is what does NOT depend on which pages exist: that reading
  # fills the table from the catalogue by itself.
  describe 'over the catalogue, without anybody filling the table first' do
    it 'brings the table up to date by itself before answering a query' do
      expect(ProductKnowledgeEntry.count).to eq(0)

      slugs = search.query('Platzhaltertext').map(&:slug)

      expect(slugs).to include('guides/basics/erste-seite')
      expect(ProductKnowledgeEntry.count).to be_positive
    end

    it 'finds a page by slug on a table it first has to fill' do
      expect(ProductKnowledgeEntry.count).to eq(0)

      expect(search.find('guides/basics/erste-seite')&.title).to eq('Erste Beispielseite')
    end
  end
end
