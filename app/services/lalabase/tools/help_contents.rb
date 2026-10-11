# frozen_string_literal: true

module Lalabase
  module Tools
    # Lists every page of Lalabase's own help with its slug, title, section and one-line
    # description (doc/product_knowledge_plan.md, S2, D7). It stands in for the vectors the
    # organisation's content has: full text finds a page only by its words, and a question in
    # other words ("Wie lade ich jemanden ein?" never meets "einladen") needs a reader who
    # knows what each page is about. Here the model is that reader. With one curated
    # description per page the list is about 11,000 characters a language, under 3,000 tokens,
    # paid only when called; the catalogue (D8) measures whether it is enough.
    class HelpContents < HelpTool
      def self.tool_name
        'help_contents'
      end

      def self.description
        "Lists every page of Lalabase's own help as JSON: slug, title, section and a one-line " \
          'description. Use it when search_help finds nothing that fits, or when the question ' \
          'uses other words than a manual would. Choose the page by meaning and read it with ' \
          'get_help_page before answering.'
      end

      # No argument. The Vertex adapter sends such a tool without parameters, because Gemini's
      # schema subset refuses an OBJECT with empty properties (GoogleVertexProvider).
      def self.input_schema
        { type: 'object', properties: {} }
      end

      def self.execute(args:, context:) # rubocop:disable Lint/UnusedMethodArgument -- the Runner's contract; this tool takes none
        search = help_search(context)
        pages = search.contents
        # Every language has pages once the table is there (Sources refuses one without), so an
        # empty list only ever means the help is not available yet.
        return unavailable if pages.empty?

        json_result(
          {
            # The language the help is read in: the asker's, which need not be the chat's.
            locale: search.locale,
            data: pages.map { |page| row(page, search.locale) }
          },
          # Nothing cited, deliberately: this is the list of pages, not their text. An answer
          # draws on the page the model reads next, and get_help_page cites that one. Citing
          # every page would put the whole list under the answer, and the help has no area to
          # gate anyway.
          citations: []
        )
      end

      # The locale only on a page without a translation into the asker's language: the model
      # should know it reads German there, and the other rows need not say what they are.
      def self.row(page, language)
        head = page_head(page)
        page.locale == language ? head : head.merge(locale: page.locale)
      end
      private_class_method :row
    end
  end
end
