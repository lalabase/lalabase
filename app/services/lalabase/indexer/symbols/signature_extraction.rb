# frozen_string_literal: true

module Lalabase
  module Indexer
    module Symbols
      # Shared signature extraction for the per-language symbol extractors
      # (RubyExtractor, TypescriptExtractor, …). A "signature" is just the first
      # few source lines of a declaration — enough to show the name and opening
      # arguments — capped in length so a minified one-liner can't bloat a row.
      #
      # Extracted into one place so the rule (how many lines, the length cap)
      # lives ONCE: with two+ extractors copying it the constants would silently
      # drift (someone bumps the cap in one file but not the other).
      #
      # Contract: the including class must set `@source_lines` (the source split
      # into lines, e.g. `source.lines`). Kept as a mixin — rather than a function
      # taking the lines — so every extractor's call site stays the plain
      # `extract_signature(start_line)`.
      module SignatureExtraction
        SIGNATURE_LINE_LIMIT = 3 # first N lines of a decl — sig + opening args
        MAX_SIGNATURE_LENGTH = 500 # hard cap against a pathological one-liner

        private

        def extract_signature(start_line)
          first = [start_line - 1, 0].max
          last = [first + SIGNATURE_LINE_LIMIT - 1, @source_lines.length - 1].min
          sig = @source_lines[first..last].to_a.join.strip
          sig[0, MAX_SIGNATURE_LENGTH].to_s
        end
      end
    end
  end
end
