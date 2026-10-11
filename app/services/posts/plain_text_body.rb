# frozen_string_literal: true

# Converts literal text to ActionText HTML: CR and CRLF become LF, blank lines
# at the edges are dropped, blank lines inside separate paragraphs, a single
# line break becomes <br>. Spaces and tabs stay ordinary HTML whitespace.
# Entry point: call
module Posts
  class PlainTextBody
    # A run of blank lines (ASCII spaces and tabs only) at either edge.
    EDGE_BLANK_LINES = /\A(?:[ \t]*\n)+|(?:\n[ \t]*)+\z/

    def self.call(body:)
      text = body.gsub(/\r\n?/, "\n").gsub(EDGE_BLANK_LINES, '')
      paragraphs = text.split(/\n(?:[ \t]*\n)+/).reject(&:blank?)
      paragraphs.map { |paragraph| "<p>#{CGI.escapeHTML(paragraph).gsub("\n", '<br>')}</p>" }.join
    end
  end
end
