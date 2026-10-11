# frozen_string_literal: true

module Lalabase
  module Tools
    # Reads one page of Lalabase's own help as JSON (doc/product_knowledge_plan.md, S2), the
    # counterpart of get_ticket for the help, addressed by the slug search_help and
    # help_contents hand out.
    #
    # The text is the page's MARKDOWN, because headings and lists are what a how-to answer is
    # built from. Its links are the exception. Authors write them relative to the page, as
    # Markdown links or, inside HTML blocks, as <a href> ("../team/invite-members"), which means
    # nothing to a model. And a /hilfe link the model copies into its answer opens inside the
    # chat's turbo frame and shows "Content missing": the answer HTML carries no frame escape,
    # only the source list and CitationInlineLinks add one. So a link to another help page
    # becomes its text plus PAGE_REFERENCE, which the model can read on with this tool, and the
    # page is linked by its citation under the answer. Which page a link addresses is
    # Docs::PageLinks' decision, shared with the renderer.
    class GetHelpPage < HelpTool
      # Every help page fits whole: the largest, the assistant's own page, is 24,788 characters
      # in German with its links resolved (15.09.2026; guard in the spec). Raised from 24,000
      # that day by owner decision after the meeting sections (#811 to #817) grew the page past
      # it, instead of splitting the page. One read is now a quarter of a run's tool budget
      # (Runner::DEFAULT_MAX_TOOL_RESULT_CHARS) instead of a fifth; the guard asks again when
      # a page outgrows this.
      MAX_TEXT_CHARS = 30_000

      # A slug is lowercase words, digits, dashes and slashes ("guides/features/time-tracking").
      SLUG_FORMAT = %r{\A[a-z0-9][a-z0-9/-]*\z}

      # How a link to another help page reaches the model: its text, then this with the slug.
      PAGE_REFERENCE = '(help page %<slug>s)'

      # [text](target) and [text](target "title"), the help's Markdown links. Not an image.
      MARKDOWN_LINK = /(?<!!)\[([^\[\]]*)\]\(([^()\s]+)(?:\s+"[^"]*")?\)/

      # <a href="target">text</a>, the links inside the HTML blocks some help pages use.
      HTML_LINK = %r{<a\s+href="([^"]*)"[^>]*>(.*?)</a>}m

      # The canonical docs form of a slug, which a model may have seen ("docs/de/guides/...").
      DOCS_PREFIX = %r{\Adocs/(?:de|en)/}

      def self.tool_name
        'get_help_page'
      end

      def self.description
        "Reads one page of Lalabase's own help by its slug (from search_help or help_contents). " \
          'Returns JSON: title, section, description, locale and the page text as Markdown. A link ' \
          "to another help page appears as \"#{format(PAGE_REFERENCE, slug: '<slug>')}\"; read it " \
          'with this tool when the answer needs it. Such references and slugs are for you: in the ' \
          'answer name a page by its title and write no links to help pages, the sources under it ' \
          'link the pages. Quote button and menu names exactly as the page writes them. Long texts ' \
          'are cut: text_truncated says so and text_length is the full length.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            slug: { type: 'string', description: 'The page slug, e.g. "guides/features/time-tracking".' }
          },
          required: ['slug']
        }
      end

      def self.execute(args:, context:)
        slug = slug_from(symbolized(args)[:slug])
        return Result.new(error: 'slug is required') if slug.empty?
        return Result.new(error: 'invalid slug format') unless slug.match?(SLUG_FORMAT)

        search = help_search(context)
        entry = search.find(slug)
        return nothing_found(search, not_found(slug)) if entry.nil?

        json_result(payload(entry), citations: [Lalabase::Citations.help_page(entry)])
      end

      # The page's Markdown with every docs link resolved, the Markdown ones and those inside
      # HTML blocks. Public because the spec measures the conversion through it; the guards
      # that ran it over every REAL page moved to gboyke/lalabase-documentation with the text
      # (spec/content/handbook_content_spec.rb), where they approximate this length rather
      # than call it.
      def self.text_of(entry)
        text = entry.body_markdown.to_s.gsub(MARKDOWN_LINK) do
          match = Regexp.last_match
          resolved(match[0], match[1], match[2], entry.slug, entry.locale)
        end
        text.gsub(HTML_LINK) do
          match = Regexp.last_match
          resolved(match[0], CGI.unescapeHTML(match[2]), match[1], entry.slug, entry.locale)
        end
      end

      # One link as the model reads it: a page this instance HAS as its text plus
      # PAGE_REFERENCE, so the model can fetch it; a page it does not have as bare text,
      # because a reference the model cannot follow is worse than no reference; anything else
      # (external, a pure anchor) as written.
      #
      # "Has it" used to mean "is on the same surface". It means "is in the catalogue" now,
      # which is the same question asked of the thing that actually answers it.
      def self.resolved(whole, label, href, base_slug, locale)
        slug, anchor = Docs::PageLinks.target(href, base_slug: base_slug)
        return whole if slug.nil?
        # find_page, not for(locale)&.page: it falls back to German the way the
        # help does, so a page the reader's own catalogue lacks is still a
        # reference the model can follow instead of collapsing to bare text.
        return label unless Docs::Catalogue.find_page(locale, slug)

        "#{label} #{format(PAGE_REFERENCE, slug: "#{slug}#{anchor}")}"
      end
      private_class_method :resolved

      # What a model may pass besides the bare slug: the help path it saw ("/hilfe/guides/..."),
      # the canonical docs form, a slug with its section ("guides/basics/tickets#status"),
      # capitals or a trailing slash. All of them name the same page.
      def self.slug_from(raw)
        path = raw.to_s.strip.downcase.delete_prefix('/')
        path = path.delete_prefix(help_prefix).sub(DOCS_PREFIX, '')
        path.split('#', 2).first.to_s.chomp('/')
      end
      private_class_method :slug_from

      # "hilfe/", read from the route rather than spelled here: the help's address belongs to
      # config/routes.rb, and CitationLink builds its links from the same route.
      def self.help_prefix
        "#{Rails.application.routes.url_helpers.help_path.delete_prefix('/')}/"
      end
      private_class_method :help_prefix

      def self.payload(entry)
        text = text_of(entry)
        page_head(entry).merge(
          # The language of the page read: the asker's, unless the page has no translation yet
          # and Search fell back to German, as the help itself does.
          locale: entry.locale,
          text_length: text.length,
          text_truncated: text.length > MAX_TEXT_CHARS,
          text: cap_text(text, MAX_TEXT_CHARS)
        )
      end
      private_class_method :payload

      def self.not_found(slug)
        Result.new(content: "No help page found for #{slug}.", citations: [], kind: :empty)
      end
      private_class_method :not_found
    end
  end
end
