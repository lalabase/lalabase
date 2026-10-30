# frozen_string_literal: true

module Lalabase
  module Tools
    # Searches the project's knowledge (notes + documents) by TITLE and returns, per
    # hit, the ready-to-paste `lalabase://<type>/<uuid>` link string. This is the
    # AUTHORING half of Slice 4: a coding agent writing docs in the repo has no idea
    # which notes/documents exist in Lalabase, so it looks them up here and drops the
    # returned link straight into markdown — where the sync-time resolver turns it into
    # an in-app link + a Reference row. The link string is produced by the SAME builder
    # the resolver parses (Documentation::KnowledgeLink), so authoring can't drift.
    #
    # The rows come from Knowledge::Lookup, the one read GET /api/v1/projects/:project_id/knowledge
    # uses too (cli_rest_plan D5): per-type Pundit.policy_scope!, the merge page, the total and
    # the serialization live there. This tool keeps what is MCP's own: `q` is required, page and
    # per_page are read leniently (garbage = default, a large per_page is clamped), and the
    # citations. Read-only tool → runs with a read-only PAT.
    class SearchKnowledge < Base
      MAX_PER_PAGE = Knowledge::Lookup::MAX_PER_PAGE
      DEFAULT_PER_PAGE = Knowledge::Lookup::DEFAULT_PER_PAGE

      # Same reasoning as ListTickets::MAX_CITATIONS: the gate needs one citation per area,
      # a full page of source chips under a lookup answer helps nobody.
      MAX_CITATIONS = 5

      # Reads context.actor for its Pundit scoping — declared so the Runner's
      # fail-closed bar refuses the call when no user is in the context.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'search_knowledge'
      end

      def self.description
        'Searches the project\'s knowledge (notes and documents) by TITLE; returns JSON ' \
          'hits, newest first. Each hit carries a ready-to-paste `link` string of the form ' \
          'lalabase://<type>/<uuid>. Insert that link UNCHANGED into documentation markdown ' \
          'as a normal [display text](link) link: on the next sync Lalabase resolves it to ' \
          'an in-app link to the note/document. Optional filters: type ("note" or ' \
          '"document"), page, per_page. Scoped to what the authenticated user may read — no ' \
          'read access to a type simply yields no hits of that type.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            q: { type: 'string', description: 'Search term matched (case-insensitively) against note/document titles.' },
            type: { type: 'string', description: 'Optional. Restrict to "note" or "document".' },
            page: { type: 'integer', description: 'Page number, 1-based.' },
            per_page: { type: 'integer', description: "Items per page (max #{MAX_PER_PAGE})." }
          },
          required: ['q']
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil?

        args = symbolized(args)
        return Result.invalid_input('q is required') if args[:q].to_s.strip.empty?

        begin
          options = Knowledge::Lookup.options(args)
        rescue Knowledge::Lookup::InvalidOption => e
          return Result.invalid_input(e.message)
        end

        found = Knowledge::Lookup.new(user: context.actor, project: context.project).page(options)
        records = found.records
        json_result(
          found.to_h,
          # Titles of notes and documents are content, and the answer's rights gate runs on
          # the citations' `area` (Chatpost#gated_streaming?, MessageComponent#redacted?),
          # not on the asker. Without them an answer built from this tool would be
          # content-free and reach every reader of a shared chat. Today the tool lives in
          # :mcp only (outside the LLM loop), so this changes nothing now — it means
          # offering it to a chat set later stays a registry line instead of a security review.
          citations: records.first(MAX_CITATIONS).filter_map { |record| citation_for(record) }
        )
      end

      # Note → note citation, Document → its current version (Citations.document reads the
      # title off the version). nil for anything else, the caller compacts.
      #
      # The version's `document` association is filled in from the row we already hold:
      # Citations.document calls document_version.document, which would otherwise be one
      # SELECT per cited row. Same value, no write — it only spares the round trip. The
      # N+1 guard on this tool's spec is what caught the naive version.
      def self.citation_for(record)
        case record
        when Note then Lalabase::Citations.note(record)
        when Document
          version = record.current_version
          version && Lalabase::Citations.document(version.tap { |v| v.document = record })
        end
      end
      private_class_method :citation_for
    end
  end
end
