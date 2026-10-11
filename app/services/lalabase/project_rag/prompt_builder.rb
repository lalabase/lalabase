# frozen_string_literal: true

module Lalabase
  module ProjectRag
    # Converts a Retriever::Result into a system-prompt context block.
    #
    # Output: a single string that can be prepended to (or merged with) the
    # existing system prompt. Layout is stable & deterministic so prompt-cache
    # in the provider isn't busted by reordering.
    #
    # When the result is empty, returns an empty string — caller decides whether
    # to skip injection entirely.
    class PromptBuilder
      # Cap per-symbol signature length inside the prompt to bound token cost.
      MAX_SIGNATURE_IN_PROMPT = 200
      # Cap capability description length inside the prompt.
      MAX_DESCRIPTION_IN_PROMPT = 400
      # Hard cap on Vision content (already capped at write-time, but defense in depth).
      MAX_VISION_IN_PROMPT = 4000
      # Cap per project-content item (ticket/note/document/post excerpt) in the prompt.
      MAX_CONTENT_ITEM_IN_PROMPT = 500

      # Closing instruction that activates the source-attribution marker
      # (chat_quellen_attribution_plan.md §6.1). Hardcoded English like the section
      # headers below — the RAG block is deterministic English regardless of chat
      # language (provider prompt-cache). The `[[used_sources: …]]` examples are prompt
      # text only; SourceAttribution.parse only ever runs on the model's ANSWER,
      # never on this prompt text.
      #
      # The wording is load-bearing (§6.4, follow-up to the first in-prod measurement:
      # gemini-2.5-flash dropped the marker on an "I don't have enough information"
      # answer → marker_found=false → lossless fallback → all 8 sources shown, i.e.
      # exactly the pre-feature symptom). Three deliberate properties:
      #   * Its OWN `##` section, not a trailing line inside `## Project Context` —
      #     within the context block it reads as data to be summarised, not as a rule
      #     addressed to the model.
      #   * Unconditional ("EVERY reply", with the no-answer case named explicitly):
      #     a refusal is where trailing format requirements get dropped first, and at
      #     the same time where a bogus source list is most glaring to the reader.
      #   * No "do not mention this line" (the previous phrasing) — that is readable
      #     as "leave the line out" and so defeats the instruction carrying it.
      ATTRIBUTION_INSTRUCTION = <<~INSTRUCTION.strip
        ## Answer Format (mandatory)
        End EVERY reply with exactly one line in this machine-readable format:

        [[used_sources: 1, 3]]

        List the numbers of the sources above that you actually relied on. If you
        relied on none, the line reads [[used_sources: none]] — this includes the case
        where the context does not cover the question and you cannot answer it.
        Never leave this line out. Put it on its own final line, without explaining or
        commenting on it.
      INSTRUCTION

      # `name_projects` (S3a T3): label every content item with its project. The
      # assistant prompt asks the model to name where a statement comes from, so the
      # data must carry it. The default stays false for a caller with one project and
      # nothing to disambiguate; ChatResponseJob passes true.
      def initialize(result:, name_projects: false)
        @result = result
        @name_projects = name_projects
      end

      def call
        return '' if @result.blank?

        # ONE numbering over Result#citations, shared with the job's marker parser
        # (SourceNumbering). Inactive for an empty citation list → no numbers, no
        # instruction: a code-only unit Result renders exactly as before the feature.
        @numbering = SourceNumbering.for(@result.citations)
        sections = []
        sections << vision_section     if @result.vision
        sections << capability_section if @result.capabilities.any?
        sections << symbol_section     if @result.symbols.any?
        # Project content goes LAST — additive append keeps the provider prompt-cache
        # prefix (Vision/Capabilities/Symbols) byte-stable across requests (Plan §5).
        # to_a: content is nil on a code-only Result built without the field (same
        # defensive reason as Result#empty?).
        sections << content_section if @result.content.to_a.any?
        # No `return '' if sections.empty?` — unreachable: the `@result.empty?`
        # guard above already covers vision=nil && caps=[] && symbols=[] && content=[].
        parts = [header] + sections
        # The instruction follows the context as its own section, and ONLY when there
        # are numbered sources to reference (§6.1) — context-free chats + the ticket
        # chat stay bare.
        parts << ATTRIBUTION_INSTRUCTION if @numbering.active?
        parts.join("\n\n")
      end

      private

      def header
        '## Project Context'
      end

      def vision_section
        content = @result.vision.content.to_s[0, MAX_VISION_IN_PROMPT]
        "### Vision\n#{citation_prefix('vision', @result.vision)}#{content}"
      end

      def capability_section
        rows = @result.capabilities.map do |cap|
          desc = cap.description.to_s[0, MAX_DESCRIPTION_IN_PROMPT]
          "- #{citation_prefix('capability', cap)}**#{cap.name}**: #{desc}"
        end
        "### Capabilities\n#{rows.join("\n")}"
      end

      def symbol_section
        rows = @result.symbols.map do |sym|
          sig = Lalabase::FenceGuard.sanitize(sym.signature.to_s[0, MAX_SIGNATURE_IN_PROMPT])
          "- #{citation_prefix('symbol', sym)}`#{sym.qualified_name}` " \
            "(#{sym.file_path}:#{sym.start_line})\n  ```\n  #{sig}\n  ```"
        end
        "### Relevant Code Symbols\n#{rows.join("\n")}"
      end

      # Project-content section (Plan §4.3). Content is USER-GENERATED → both the
      # label (titles) and the excerpt MUST pass through FenceGuard (prompt-injection
      # vector), unlike the trusted Vision/Capability sections above. Each item maps
      # 1:1 to a content citation built from the same Result#content (the §9 coupling
      # that backs sourced_areas).
      def content_section
        rows = @result.content.map do |fragment|
          label   = Lalabase::FenceGuard.sanitize("#{content_label(fragment)}#{origin_suffix(fragment)}")
          excerpt = Lalabase::FenceGuard.sanitize(fragment.plain_text_content.to_s[0, MAX_CONTENT_ITEM_IN_PROMPT])
          "- #{content_citation_prefix(fragment)}**#{label}**\n  #{excerpt}"
        end
        "### Project Knowledge (Tickets, Notes, Documents)\n#{rows.join("\n")}"
      end

      # " (project: Name)" for a content item when name_projects is on. Resolved
      # through the citation shape (it already knows each type's project_id) and
      # ONE name lookup per prompt. Sanitised together with the label by the caller.
      def origin_suffix(fragment)
        return '' unless @name_projects

        cite = Lalabase::Citations.for_fragment(fragment)
        name = cite && project_names[cite[:project_id]]
        name ? " (project: #{name})" : ''
      end

      def project_names
        @project_names ||= begin
          ids = @result.content.filter_map { |f| Lalabase::Citations.for_fragment(f)&.dig(:project_id) }.uniq
          ids.empty? ? {} : Project.where(id: ids).pluck(:id, :name).to_h
        end
      end

      # "[n] " prefix for a code-layer item (vision/capability/symbol). Empty when the
      # numbering is inactive (no citations) — the id is read ONLY then, so the code
      # sections don't require an id on an unnumbered Result (keeps unit Results simple).
      def citation_prefix(type, obj)
        return '' unless @numbering.active?

        numbered_prefix(type, obj.id)
      end

      # "[n] " prefix for a content item. Resolves the fragment to its (type, id) via the
      # shared citation shape so two fragments of one deduped ticket share a number
      # (§6.1). Empty when inactive or the fragment maps to no citation (defensive).
      def content_citation_prefix(fragment)
        return '' unless @numbering.active?

        cite = Lalabase::Citations.for_fragment(fragment)
        return '' if cite.nil?

        numbered_prefix(cite[:type], cite[:id])
      end

      # Shared tail of the two prefix builders above.
      def numbered_prefix(type, id)
        number = @numbering.number_for(type, id)
        number ? "[#{number}] " : ''
      end

      # Human-readable label per content item. Type list mirrors ContentAreaRegistry
      # (sync all four places listed in its header when adding a type). The `else`
      # fallback keeps an unknown type from crashing the prompt — it would already
      # have been excluded upstream (fail-closed), so this is pure defense in depth.
      def content_label(fragment)
        f = fragment.fragmentable
        case fragment.fragmentable_type
        when 'Ticket'            then "Ticket ##{f.number}: #{f.title}"
        when 'Post'              then "Comment on ticket ##{f.ticket.number}"
        when 'Note'              then "Note: #{f.title}"
        when 'DocumentVersion'   then "Document: #{f.title}"
        when 'DocumentationPage' then "Documentation: #{f.title}"
        # The only place the FILE is named at all, since the citation points at the
        # ticket. Without it an answer drawn from an attachment reads as an answer from
        # the ticket body, which is a quieter kind of wrong than not answering.
        # squish, because a filename is user-controlled and FenceGuard only neutralises
        # fences: a newline in it would otherwise open a fresh markdown line INSIDE the
        # label — a fake source entry or heading in the system prompt. The label is a
        # one-liner by contract, so collapsing whitespace loses nothing.
        when 'TicketDocument'    then "Attachment on ticket ##{f.ticket.number}: #{f.filename.squish}"
        when 'PostDocument'      then "Attachment on a comment on ticket ##{f.post.ticket.number}: #{f.filename.squish}"
        when 'Meeting'           then "Meeting: #{f.title}"
        when 'MeetingAnalysis'   then "Meeting analysis: #{f.prompt_title}"
        else 'Project source'
        end
      end
    end
  end
end
