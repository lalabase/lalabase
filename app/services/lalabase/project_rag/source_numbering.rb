# frozen_string_literal: true

# Entry point: for (build a numbering) / apply_used_flags
module Lalabase
  module ProjectRag
    # THE single derivation of "prompt number n ↔ citations[n-1]", shared by the two
    # sides of the attribution mechanism (chat_quellen_attribution_plan.md §6):
    #
    #   * PromptBuilder numbers each context item so the model can reference it
    #     (`.for(citations)` → `#number_for(type, id)`), and
    #   * ChatResponseJob maps the model's `[[used_sources: …]]` marker back onto the
    #     citation positions (`.apply_used_flags`).
    #
    # Two independent derivations of the same 1-based ordering would drift; keeping
    # both here (number = citation index + 1) guarantees they agree. A PromptBuilder
    # spec additionally pins that its numbering equals the Result#citations order.
    #
    # The numbering is over the DEDUPED Result#citations, so several fragments of the
    # same ticket share one number. Positions at/after `initial_count` in
    # apply_used_flags are append-only runtime tool citations — the model never saw a
    # number for them, so they default to used (§6.2).
    class SourceNumbering
      # Build a numbering over an ordered, deduped citation list (Result#citations).
      def self.for(citations)
        new(citations: citations)
      end

      def initialize(citations:)
        list = citations.is_a?(Array) ? citations : []
        @index = {}
        list.each_with_index do |cite, i|
          next unless cite.is_a?(Hash)

          @index[key_for(cite[:type] || cite['type'], cite[:id] || cite['id'])] = i + 1
        end
      end

      # True when there is at least one numbered citation. PromptBuilder skips
      # numbering AND the marker instruction entirely when false — an empty
      # Result#citations (e.g. a code-only unit Result) then renders exactly as
      # before the feature.
      def active?
        @index.any?
      end

      # 1-based prompt number for the citation identified by (type, id), or nil when
      # that citation is not in the list. type may be a Symbol or a String.
      def number_for(type, id)
        @index[key_for(type, id)]
      end

      # Returns a COPY of `citations` with an additive `used:` flag on every hash,
      # derived from a SourceAttribution.parse result. Never mutates the input, never
      # drops/reorders/reshapes a citation (§3: the gate keeps reading the full list).
      #
      # @param citations [Array<Hash>] runner.citations — the deduped Result#citations
      #   followed by append-only runtime tool citations.
      # @param initial_count [Integer] number of numbered (prompt) citations
      #   (= initial_citations.size). Positions from here on are tool citations.
      # @param parse_result [Hash] output of SourceAttribution.parse.
      def self.apply_used_flags(citations:, initial_count:, parse_result:)
        return citations unless citations.is_a?(Array)

        used = resolve_used_numbers(parse_result, initial_count)
        citations.each_with_index.map do |cite, i|
          next cite unless cite.is_a?(Hash)

          is_used = i >= initial_count || used == :all || used.include?(i + 1)
          cite.merge(used: is_used)
        end
      end

      # The concrete set of numbered positions counting as "used", or :all for the
      # lossless fallback. Fallback (:all, every numbered source stays visible) covers
      # "no marker" AND "only unknown/out-of-range numbers" — never worse than the
      # pre-feature behaviour. An explicit `none` yields the empty set (§9).
      def self.resolve_used_numbers(parse_result, numbered_count)
        return :all unless parse_result[:marker_found]

        indices = parse_result[:used_indices]
        return [] if indices == :none

        valid = indices.select { |n| n.is_a?(Integer) && n >= 1 && n <= numbered_count }
        valid.empty? ? :all : valid.uniq
      end

      private

      def key_for(type, id)
        [type.to_s, id]
      end
    end
  end
end
