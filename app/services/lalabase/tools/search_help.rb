# frozen_string_literal: true

module Lalabase
  module Tools
    # Finds pages of Lalabase's own help by words (doc/product_knowledge_plan.md, S2), the
    # counterpart of list_tickets for the help. Full text through ProductKnowledge::Search, so
    # stems, prefixes and a whole question work. A question in OTHER words than the help uses
    # ("Wie lade ich jemanden ein?" never meets "einladen") is what help_contents is for, and so
    # is a page without a translation into the asker's language: the search stays in one
    # language, the contents list brings such a page in German.
    #
    # Every result names the way out: if no page fits, call help_contents and choose by meaning.
    # The first real run (12.09.2026) showed why: the model got three pages that merely shared a
    # word, decided the help had nothing, and answered from its own knowledge. Unconditional on
    # purpose. The first try made the sentence depend on "no page carries every search word", and
    # measuring the catalogue killed that: of the three questions the words miss, all three have
    # another page with every word, while four questions whose page comes first or third have no
    # such page at all. The signal fired where the search works and stayed quiet where it fails.
    # Whether the hits fit the question is a judgement about meaning, and only the model can make
    # it; the tool can only make sure it knows there is a second route.
    class SearchHelp < HelpTool
      # Three cited, not every hit. The catalogue (D8) wants the right page among the first
      # three, and each citation is a row under the answer: citations from a tool are never
      # numbered for the model, so none of them can be marked unused afterwards
      # (SourceNumbering.apply_used_flags). The page the model then reads is cited by
      # get_help_page.
      MAX_CITATIONS = 3

      # The second route, named in every result. A full text hit can share a word and miss the
      # question, and that is not visible in the hit itself.
      NEXT_STEP = 'If none of these pages answers the question, call help_contents and choose a ' \
                  'page by meaning instead of answering without a page.'

      def self.tool_name
        'search_help'
      end

      def self.description
        "Searches Lalabase's own help, the manual of the software (tickets, time tracking, " \
          'knowledge, meetings, settings, AI and this assistant), by words. Returns JSON hits, ' \
          'best first: slug, title, section, description and a snippet. Use it for questions ' \
          "about how Lalabase works or how to do something in it, never for the organisation's " \
          'own content. Read the page with get_help_page before answering from it. A hit can ' \
          'share a word and still miss the question: when none of them fits, call help_contents ' \
          'and choose by meaning instead of answering without a page.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            q: { type: 'string', description: 'Search words, e.g. "Zeit buchen". A whole question works too.' }
          },
          required: ['q']
        }
      end

      def self.execute(args:, context:)
        query = symbolized(args)[:q].to_s.strip
        return Result.new(error: 'q is required') if query.empty?

        search = help_search(context)
        hits = search.query(query)
        return nothing_found(search, no_match(search)) if hits.empty?

        json_result(payload(search, hits),
                    citations: hits.first(MAX_CITATIONS).map { |hit| Lalabase::Citations.help_page(hit) })
      end

      def self.payload(search, hits)
        {
          # The language the help is read in: the asker's, which need not be the chat's.
          locale: search.locale,
          next_step: NEXT_STEP,
          data: hits.map { |hit| page_head(hit).merge(snippet: hit.snippet) }
        }
      end
      private_class_method :payload

      # An empty SUCCESS that points at the other ways in, not an error: "the help does not use
      # these words" is an answer. It names the help's language, because the model writes the
      # search words in the chat's language, and the help is read in the asker's (review of the
      # S2 PR).
      def self.no_match(search)
        Result.new(content: "No help page matches these words. The help is in \"#{search.locale}\": " \
                            'search in that language, or choose from help_contents.',
                   citations: [], kind: :empty)
      end
      private_class_method :no_match
    end
  end
end
