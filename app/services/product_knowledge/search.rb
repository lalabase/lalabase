# frozen_string_literal: true

# Full-text search over Lalabase's own texts in product_knowledge_entries.
# Entry point: query (and find, for one page; contents, for every page)
module ProductKnowledge
  # The ONE reader of the table (doc/product_knowledge_plan.md, "Search"), for the assistant's
  # help tools and later the in-app help search. Every read brings the table up to date first
  # (EnsureFresh), so no caller can forget to.
  #
  # A query finds pages in three passes, each one only adding what the one before missed:
  #   1. Full text with every term. Postgres drops the language's stop words and stems the
  #      rest ("Wie lade ich Mitglieder ein?" asks for lad, mitglied), and each term also
  #      counts as a prefix ("Zeit" finds "Zeiterfassung"). Ranked by cover density, a hit in
  #      the title above one in the description above one in the text.
  #   2. While there is room: full text with any of the terms, ranked the same way, after the
  #      pages that have them all. A whole question rarely matches word for word, and a
  #      separable verb ("lade ... ein") never meets its infinitive ("einladen").
  #   3. Always: a literal match of the whole term in title, description or text, after the
  #      ranked hits. It catches what stemming misses ("Zeit" inside "Arbeitszeit").
  # Every hit says which pass found it (Hit#match), because that is the difference between a
  # page that answers the question and a page that merely shares a word.
  # One language per answer.
  class Search
    # match: how the hit was found. ALL_TERMS is a page the words really landed on; the other
    # two are guesses, and the help tools tell the model so (review of the first real run,
    # 12.09.2026: it answered from its own knowledge rather than reach for the contents list).
    Hit = Struct.new(:source, :locale, :slug, :title, :section, :description, :snippet, :match,
                     keyword_init: true)
    ALL_TERMS = :all_terms
    SOME_TERMS = :some_terms
    LITERAL = :literal

    # The columns a Hit is built from, the snippet and the match kind aside: #contents reads no
    # more than these.
    HIT_COLUMNS = (Hit.members - %i[snippet match]).freeze

    MIN_TERM_LENGTH = Docs::Contract::MIN_TERM_LENGTH
    MAX_RESULTS = 8
    MAX_TERMS = 8
    CONFIGS = { 'de' => 'german', 'en' => 'english' }.freeze
    # A plain snippet: the readers are a language model and a line of plain text, and
    # neither wants <b> tags.
    HEADLINE_OPTIONS = 'MaxWords=30, MinWords=12, ShortWord=2, MaxFragments=1, StartSel="", StopSel=""'

    # The language this search answers in, after the fallback for one it does not know.
    attr_reader :locale

    # sources: what this caller reads. The help by default, so a source added later (the news
    # in S3) never widens an existing caller by itself. limit: the tool wants MAX_RESULTS, the
    # in-app help search (S4) its own.
    def initialize(locale:, sources: [Sources::HELP], limit: MAX_RESULTS)
      @locale = CONFIGS.key?(locale.to_s) ? locale.to_s : Docs::Contract::DEFAULT_LOCALE
      @sources = Array(sources)
      @limit = limit
    end

    # @return [Array<Hit>] at most limit, the ranked hits first.
    def query(term)
      term = term.to_s.strip
      return [] if term.length < MIN_TERM_LENGTH

      EnsureFresh.call
      hits = ranked(terms_of(term))
      (hits + literal(term, found: hits.map(&:slug))).first(@limit)
    end

    # One entry by slug in this language, else in German: the help's own rule for a page
    # that has no translation yet (as Docs::Catalogue.find_page does). nil when neither exists. One
    # query for both languages rather than a second lookup after a miss.
    def find(slug)
      EnsureFresh.call
      candidates = scope.where(slug: slug, locale: languages).to_a
      candidates.find { |entry| entry.locale == @locale } || candidates.first
    end

    # Every page for a table of contents, whatever the limit: slug, title, section and
    # description, no text and no snippet. The assistant's help_contents hands it to the model
    # to choose a page by meaning (D7). A page without a translation into this language comes
    # in German, by the same rule as #find, so a page the translators have not reached yet
    # stays discoverable; its locale says which it is (review of the S2 PR). Ordered by section,
    # then title: the table keeps no position of its own, and a contents list is read by section.
    def contents
      EnsureFresh.call
      entries = scope.where(locale: languages).select(*HIT_COLUMNS).to_a
      translated = entries.select { |entry| entry.locale == @locale }.to_set(&:slug)
      entries.reject! { |entry| entry.locale != @locale && translated.include?(entry.slug) }
      entries.sort_by { |entry| [entry.section.to_s, entry.title.to_s] }.map { |entry| hit(entry, nil, nil) }
    end

    # Whether the table holds anything of these sources at all. Asked after a read that found
    # nothing: false only before the first sync has committed (a fresh install, while another
    # process holds the lock) or when the table was emptied, and then "no such page" would be a
    # false answer (review of the S2 PR).
    def available?
      scope.exists?
    end

    private

    # This language, then the help's default for a page without a translation.
    def languages
      [@locale, Docs::Contract::DEFAULT_LOCALE].uniq
    end

    # The pages with every term first; while there is room, the pages with only some after.
    def ranked(terms)
      return [] if terms.empty?

      hits = full_text(terms, '&', ALL_TERMS)
      return hits if terms.size == 1 || hits.size >= @limit

      found = hits.map(&:slug)
      hits + full_text(terms, '|', SOME_TERMS).reject { |hit| found.include?(hit.slug) }
    end

    # The language's own normalisation, done by Postgres: stop words out, the rest stemmed, in
    # the order they were asked. Only letters and digits reach the tsquery, so no input can
    # touch its syntax (& | ! : ( ) ' \) and raise. A one-letter term would match nearly
    # everything as a prefix and is dropped.
    def terms_of(term)
      sql = ProductKnowledgeEntry.sanitize_sql_array(
        ["SELECT string_agg(lexeme, ' ' ORDER BY positions[1]) FROM unnest(to_tsvector(?::regconfig, ?))",
         config, term]
      )
      lexemes = ProductKnowledgeEntry.connection.select_value(sql).to_s
      lexemes.scan(/[\p{L}\p{N}]+/).select { |word| word.length >= MIN_TERM_LENGTH }.uniq.first(MAX_TERMS)
    end

    # The terms already are the language's lexemes (terms_of), so the query is cast, not parsed
    # again: a second pass through the dictionary drops a stem that is itself a stop word
    # ("Einigungen" stems to "einig", a German stop word; review of #806).
    def full_text(terms, operator, match)
      tsquery = terms.map { |word| "#{word}:*" }.join(" #{operator} ")
      in_locale.where('search_vector @@ ?::tsquery', tsquery)
               .select(ranked_columns(tsquery))
               .order('rank DESC', :title)
               .limit(@limit)
               .map { |entry| hit(entry, entry.headline, match) }
    end

    # ts_rank_cd (cover density), not ts_rank: it rewards terms that stand close together.
    # Measured on the real help (11.09.2026): for "Zeit buchen", "Mitglied einladen" and
    # "Status ändern" it puts the page about exactly that first, where ts_rank preferred a
    # page that merely uses both words often. The weights (title, description, text) apply.
    def ranked_columns(tsquery)
      ProductKnowledgeEntry.sanitize_sql_array(
        ['product_knowledge_entries.*, ts_rank_cd(search_vector, ?::tsquery) AS rank, ' \
         'ts_headline(?::regconfig, body_text, ?::tsquery, ?) AS headline',
         tsquery, config, tsquery, HEADLINE_OPTIONS]
      )
    end

    def literal(term, found:)
      pattern = "%#{ProductKnowledgeEntry.sanitize_sql_like(term)}%"
      entries = in_locale.where('title ILIKE :p OR description ILIKE :p OR body_text ILIKE :p', p: pattern)
                         .where.not(slug: found).order(:title).limit(@limit)
      entries.map { |entry| hit(entry, literal_snippet(entry, term), LITERAL) }
    end

    def literal_snippet(entry, term)
      Docs::PlainText.excerpt(entry.body_text, entry.body_text.downcase.index(term.downcase))
    end

    def hit(entry, snippet, match)
      Hit.new(source: entry.source, locale: entry.locale, slug: entry.slug, title: entry.title,
              section: entry.section, description: entry.description, snippet: snippet.to_s.squish,
              match: match)
    end

    def in_locale
      scope.where(locale: @locale)
    end

    def scope
      ProductKnowledgeEntry.where(source: @sources)
    end

    def config
      CONFIGS.fetch(@locale)
    end
  end
end
