# frozen_string_literal: true

# Entry point: parse / strip
module Lalabase
  module ProjectRag
    # Parses and strips the inline source-attribution marker a chat answer ends with
    # (mechanism B1, chat_quellen_attribution_plan.md §4/§6). The model is instructed
    # to close its answer with exactly one machine-readable line, e.g.
    #
    #   [[used_sources: 1,3]]      or      [[used_sources: none]]
    #
    # `parse` extracts the referenced source numbers (last marker wins; the flag
    # application in SourceNumbering resolves out-of-range/none/fallback). `strip`
    # removes every complete marker AND a partial marker still arriving at the very
    # end of the string — the streaming intermediate where only a prefix of the
    # marker has been received (§6.3). Both are pure text operations: no model call,
    # no persistence, provider-agnostic.
    module SourceAttribution
      # A well-formed marker for PARSING: opener, an optional `none` OR a
      # digits/commas/whitespace list, then the closer. Whitespace-tolerant around
      # opener and colon (mild formatting drift still parses); case-insensitive so
      # an upper-cased imitation is caught. Only this strict form is trusted for
      # number extraction.
      MARKER = /\[\[\s*used_sources\s*:\s*(none|[0-9,\s]*)\]\]/i

      # The lenient full-marker form for STRIPPING only: ANY payload up to the
      # closer. Decoupled from the parse strictness (P2 review find): a model that
      # deviates inside the payload — "[[used_sources: 1 and 3]]" — must still never
      # show the marker to the reader. parse falls back to "show all", strip removes
      # the imitation regardless.
      STRIP_MARKER = /\[\[\s*used_sources\s*:[^\]]*\]\]/i

      # Every marker begins with this literal opener. Used to recognise a partial
      # marker at the end of a still-streaming answer.
      OPENER = '[[used_sources:'

      # A partial marker anchored to the end of the string: either the opener with
      # a still-incomplete payload (any chars, at most one closing bracket), or just
      # a prefix of the opener itself (longest alternative first so the maximal
      # partial is removed). Prefixes start at TWO characters ("[[") — a legitimate
      # answer ending in a single "[" (code, a markdown link being written) must
      # never be nibbled (review find).
      PARTIAL_MARKER_SUFFIX = Regexp.new(
        '(?:' \
        '\[\[\s*used_sources\s*:[^\]]*\]?' \
        '|' \
        "#{(2..OPENER.length).map { |n| Regexp.escape(OPENER[0, n]) }.reverse.join('|')}" \
        ')\z',
        Regexp::IGNORECASE
      )

      module_function

      # @return [Hash] { marker_found: Boolean, used_indices: [Integer] | :none }
      #   marker_found false ⇒ no marker at all (→ lossless "show all" fallback).
      #   used_indices :none ⇒ the model explicitly used no numbered source.
      #   used_indices []    ⇒ marker present but no valid number (empty/garbled) —
      #                        the flag application treats this like the fallback.
      # Multiple markers: the LAST one wins (§9). Numbers are raw here; range
      # validation happens in SourceNumbering, which knows how many sources exist.
      def parse(content)
        markers = content.to_s.scan(MARKER)
        return { marker_found: false, used_indices: [] } if markers.empty?

        payload = markers.last.first.to_s.strip
        return { marker_found: true, used_indices: :none } if payload.casecmp?('none')

        indices = payload.split(',').filter_map do |token|
          stripped = token.strip
          stripped.to_i if stripped.match?(/\A\d+\z/)
        end.select(&:positive?)
        { marker_found: true, used_indices: indices }
      end

      # Removes every complete marker (lenient form — also payloads parse would
      # reject) plus a trailing partial marker. Returns the input UNCHANGED (same
      # object) when there is nothing to remove, so a normal answer is never
      # altered — the render path relies on this to stay inert.
      def strip(content)
        text = content.to_s
        stripped = text.gsub(STRIP_MARKER, '').sub(PARTIAL_MARKER_SUFFIX, '')
        return text if stripped == text

        stripped.rstrip
      end
    end
  end
end
