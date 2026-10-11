# frozen_string_literal: true

module Lalabase
  module Indexer
    # Shared builders for the natural-language user-prompt that VisionGenerator and
    # CapabilityGenerator derive from a RepoScanner result. Both format the README
    # and CLAUDE.md blocks the same way and join sections with the same separator;
    # only the extra sections (manifests, top-level heading wording, language hint)
    # and the empty-repo fallback differ, so those stay inline in each generator.
    module ScanPrompt
      SECTION_SEPARATOR = "\n\n---\n\n"

      module_function

      # README + CLAUDE.md sections common to every generator, in order. Returns a
      # (possibly empty) array of formatted strings the caller appends its own
      # generator-specific sections to.
      def doc_sections(scan)
        sections = []
        if (readme = scan[:readme])
          sections << "## #{readme[:name]}\n\n#{readme[:content]}"
        end
        if (claude = scan[:claude_md])
          sections << "## #{claude[:name]}\n\n#{claude[:content]}"
        end
        sections
      end

      # Join the assembled parts with the standard separator, or fall back to the
      # generator-specific message when there was no metadata at all.
      def join_or(parts, fallback)
        parts.join(SECTION_SEPARATOR).presence || fallback
      end
    end
  end
end
