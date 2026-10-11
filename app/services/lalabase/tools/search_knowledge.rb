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
    # Security (project-mode, D7): results come exclusively through Pundit.policy_scope!,
    # per type, in the project context. A PAT user without notes/documents READ access
    # gets an empty list for that type — never a foreign title. This is the SAME gate the
    # chat's double-gate relies on; leaking titles here (the MCP side-door) would be the
    # exact hole it exists to close. Read-only tool → runs with a read-only PAT.
    #
    # Reuse (not duplication): the per-type search arm (incl. the document→current_version
    # title join) comes from Knowledge::TypeRegistry, and the link from KnowledgeLink —
    # this tool only wraps each arm in policy_scope, paginates, and shapes the JSON. We do
    # NOT reuse KnowledgeSearchQuery: it gates by whole-type accessible keys rather than
    # per-record policy_scope, and its UNION/pagy/smart-folder/ad-hoc machinery is far
    # heavier than a title lookup needs.
    class SearchKnowledge < Base
      # Cap shared with the ticket list + HTTP API so the two agent-facing surfaces
      # bound page size the same way.
      MAX_PER_PAGE = Tickets::Filter::MAX_PER_PAGE
      DEFAULT_PER_PAGE = 10

      # Same reasoning as ListTickets::MAX_CITATIONS: the gate needs one citation per area,
      # a full page of source chips under a lookup answer helps nobody.
      MAX_CITATIONS = 5

      # Title-only search (not content): the agent is looking for a specific object to
      # link, the mentions picker (the closest existing precedent) is title-only too, and
      # searching bodies would surface — and thus expose — content the link never reveals.
      SEARCH_MODE = 'title_only'

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
        query = args[:q].to_s.strip
        return Result.invalid_input('q is required') if query.empty?

        type = args[:type].to_s.strip
        return Result.invalid_input('invalid type (expected "note" or "document")') if invalid_type?(type)

        page = [args[:page].to_i, 1].max
        per_page = clamp_per_page(args[:per_page])

        records = page_of(context, query, type, page, per_page)
        # Braces required: json_result takes the payload positionally plus a
        # `citations:` keyword, so a bare hash would be parsed as keyword args.
        json_result(
          {
            data: records.map { |record| serialize(record) },
            meta: { page: page, per_page: per_page, total: total(context, query, type) }
          },
          # Titles of notes and documents are content, and the answer's rights gate runs on
          # the citations' `area` (Chatpost#gated_streaming?, MessageComponent#redacted?),
          # not on the asker. Without them an answer built from this tool would be
          # content-free and reach every reader of a shared chat. Today the tool lives in
          # :mcp only (outside the LLM loop), so this changes nothing now — it means
          # offering it to a chat set later stays a registry line instead of a security review.
          citations: records.first(MAX_CITATIONS).filter_map { |record| citation_for(record) }
        )
      end

      # A non-blank type that is not a link-able knowledge type. Validated against the
      # LINK contract's types (what can actually be output as a lalabase:// link).
      def self.invalid_type?(type)
        type.present? && !Documentation::KnowledgeLink.type_keys.include?(type)
      end
      private_class_method :invalid_type?

      def self.type_keys_for(type)
        type.present? ? [type] : Documentation::KnowledgeLink.type_keys
      end
      private_class_method :type_keys_for

      # One policy-scoped, title-filtered relation per knowledge type. base_scope +
      # search_scope are Knowledge::TypeRegistry's (so the document title join lives in
      # one place); policy_scope! is the access gate wrapped around it.
      def self.arm(context, key, query)
        entry = Knowledge::TypeRegistry.fetch(key)
        scope = Pundit.policy_scope!(context.actor, entry[:base_scope].call(context.project))
        entry[:search_scope].call(scope, like_term(query), SEARCH_MODE)
      end
      private_class_method :arm

      # Merge-paginate the arms newest-first. Each arm is fetched with LIMIT = page *
      # per_page — all a correct offset-merge can ever need, since the k-th global item
      # sits at position ≤ k inside one arm. (LIMIT is an UPPER bound: with fewer matches
      # Postgres returns fewer rows, so a large page over a small result set is cheap, not
      # a memory blow-up.) The merged list is then sliced to the requested page.
      #
      # Ordering is `updated_at DESC, id ASC`, table-qualified via the arm's own arel_table:
      #   * qualified — the document arm joins document_versions, which ALSO has updated_at,
      #     so a bare ORDER BY would be ambiguous; arel_table qualifies to the arm's table
      #     and is injection-proof (no string built);
      #   * the id tiebreak MATCHES the Ruby merge sort below, so rows with an identical
      #     updated_at are cut by the LIMIT in the same order the merge expects — without it,
      #     pagination could drop or repeat a row at a tie that straddles a page boundary.
      def self.page_of(context, query, type, page, per_page)
        limit = page * per_page
        records = type_keys_for(type).flat_map do |key|
          scope = arm(context, key, query)
          table = scope.arel_table
          scope.reorder(table[:updated_at].desc, table[:id].asc).limit(limit).to_a
        end
        page_records = records.sort_by { |record| [-record.updated_at.to_f, record.id] }
                              .slice((page - 1) * per_page, per_page) || []
        preload_titles(page_records)
        page_records
      end
      private_class_method :page_of

      # A Document's title lives on its current_version; serialize would otherwise lazy-load
      # it once per row (N+1). Preload it for the final page only (already sliced to per_page)
      # — the registry arm uses a raw string join, so a Preloader run is cleaner and safer
      # here than folding includes into that query. Notes carry a title column: nothing to do.
      def self.preload_titles(records)
        documents = records.select { |record| record.is_a?(Document) }
        return if documents.empty?

        ActiveRecord::Associations::Preloader.new(records: documents, associations: :current_version).call
      end
      private_class_method :preload_titles

      def self.total(context, query, type)
        type_keys_for(type).sum { |key| arm(context, key, query).count }
      end
      private_class_method :total

      # Note#title is a column; Document#title delegates to its current_version — both
      # respond to #title, so serialization needs no per-type branch. The link string is
      # the shared contract (KnowledgeLink), guaranteeing a round-trip with the resolver.
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

      def self.serialize(record)
        {
          type: Documentation::KnowledgeLink.key_for(record),
          id: record.id,
          title: record.title,
          updated_at: record.updated_at&.iso8601,
          link: Documentation::KnowledgeLink.build(record)
        }
      end
      private_class_method :serialize

      def self.like_term(query)
        "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      end
      private_class_method :like_term

      def self.clamp_per_page(raw)
        value = raw.to_i
        return DEFAULT_PER_PAGE if value <= 0

        [value, MAX_PER_PAGE].min
      end
      private_class_method :clamp_per_page
    end
  end
end
