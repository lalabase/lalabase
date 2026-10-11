# frozen_string_literal: true

module Docs
  # Rewrites the canonical `/docs/<locale>/<slug>` hrefs the catalogue's HTML
  # carries onto the addresses this application can actually serve. At REQUEST
  # time, because the help paths carry the organisation id and can therefore
  # never be baked into a cached page.
  #
  # THREE cases, since the documentation became a public site of its own:
  #
  #   in the catalogue      -> the org-scoped help path, where the reader already is
  #   not in the catalogue  -> an absolute link into the public documentation
  #   not a docs link       -> untouched
  #
  # The middle one is new. While both surfaces lived here, a link to the other
  # one was dead and the renderer dropped it to plain text; now it points at a
  # page anybody can read, so dropping it would hide something that works.
  class HelpLinkRewriter
    def self.rewrite(html, base_path:, catalogue: nil, locale: Contract::DEFAULT_LOCALE)
      fragment = Nokogiri::HTML::DocumentFragment.parse(html.to_s)

      fragment.css('a[href]').each do |anchor|
        match = anchor['href'].match(Contract::CANONICAL_DOCS_REGEX)
        next unless match

        slug = match[1].chomp('/')
        anchor['href'] = if catalogue&.page(slug)
                           "#{base_path}/#{slug}#{match[2]}"
                         else
                           PublicDocs.url(locale: locale, slug: slug, anchor: match[2])
                         end
      end

      fragment.to_html
    end
  end
end
