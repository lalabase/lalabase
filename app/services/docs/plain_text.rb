# frozen_string_literal: true

# Plain text and a context snippet from rendered docs HTML.
# Entry point: from_html
module Docs
  # ONE owner for both. Until D5 it was shared by this application's search over the
  # documentation files and by the product knowledge table, so a hit read the same wherever it
  # came from. The file search went with the documentation; the remaining reader is
  # ProductKnowledge::Search, which cuts the snippet around a hit in a catalogue page's text.
  module PlainText
    SNIPPET_RADIUS = 60
    SNIPPET_LENGTH = 170

    module_function

    # The sanitizer serialises its text as HTML again ("&" comes back as "&amp;"), so the
    # entities are decoded afterwards: plain text must read as text in the search index, in a
    # snippet and for a language model. Whoever puts the result into HTML escapes it.
    def from_html(html)
      CGI.unescapeHTML(ActionView::Base.full_sanitizer.sanitize(html.to_s)).gsub(/\s+/, ' ').strip
    end

    # About SNIPPET_LENGTH characters around idx, with an ellipsis on each side that was cut.
    # idx nil (the hit is not in this text) gives the beginning, cut without an ellipsis.
    def excerpt(text, idx)
      text = text.to_s
      return text[0, SNIPPET_LENGTH].to_s if idx.nil?

      start = [idx - SNIPPET_RADIUS, 0].max
      cut = text[start, SNIPPET_LENGTH].to_s.strip
      prefix = start.positive? ? '… ' : ''
      suffix = (start + SNIPPET_LENGTH) < text.length ? ' …' : ''
      "#{prefix}#{cut}#{suffix}"
    end
  end
end
