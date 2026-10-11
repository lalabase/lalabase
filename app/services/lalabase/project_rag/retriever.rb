# frozen_string_literal: true

module Lalabase
  module ProjectRag
    # Retrieves project-aware context for a chat query via pgvector search.
    #
    # ONE layer since projekt_chat_abbau: project content (Tickets/Posts/Notes/
    # DocumentVersions from `fragments`), ASKER-GATED per area (Plan §3/§4), across
    # every project the asker may read, private posts excluded.
    #
    # The three code layers (vision 1:1 per project, capabilities top-K, code symbols
    # repo-scoped) went with their only caller in projekt_chat_abbau. The assistant
    # reaches the same data through its five code tools, on demand.
    #
    # Since embedding v2 PR 4b every vector layer reads through the ONE seam
    # Embeddings::NearestNeighbors (content_embeddings sidecar), which owns the
    # metric per record type: cosine for the code layers (idx_ce_code_symbol_1536_cos
    # uses vector_cosine_ops; ProjectCapability has no ANN index and runs exact) and
    # EUCLIDEAN for the content layer (idx_ce_fragment_1536_l2 uses vector_l2_ops —
    # cosine there would bypass the index). OpenAI embeddings (both the former
    # ada-002 and the current text-embedding-3-small, at native 1536 dims) are
    # L2-normalised, so L2 ranking matches cosine — the model switch preserves this.
    class Retriever
      # Top-K constant — locked as contract. Behavior changes if it moves.
      # CAPABILITY_TOP_K (5) and SYMBOL_TOP_K (10) went with the code layers in
      # projekt_chat_abbau; the tools that reach the same data carry their own caps.
      CONTENT_TOP_K = 8

      # Whitelist of citation types this retriever ever emits. Still carries the three
      # CODE types although no layer here produces them: the assistant's five code tools
      # return the same shapes (Lalabase::Citations.vision / .capability / .symbol), and
      # this whitelist is what the renderer and the render-gate read. Single source:
      # Lalabase::Citations::TYPES — shared with the renderer's
      # CitationListComponent::KNOWN_TYPES so producer + renderer can't drift. Consumers
      # (PromptBuilder, source_citations JSONB, CitationListComponent, render-gate) depend
      # on this surface.
      CITATION_TYPES = Lalabase::Citations::TYPES

      # Alias of the shared cap (see Lalabase::QueryEmbedding) — kept for the
      # "locked as contract" boundary spec + readability at the call site.
      MAX_QUERY_LENGTH = Lalabase::QueryEmbedding::MAX_QUERY_LENGTH

      # `coverage` (S3a T3, L7): on the org path, how many projects the content
      # layer reached for at least one area against all active projects; nil on
      # the single-project path (not applicable). The job merges it with the
      # tool rounds' coverage (narrowest wins) so a tool-free answer is labelled too.
      Result = Struct.new(:vision, :capabilities, :symbols, :content, :citations, :coverage,
                          keyword_init: true) do
        def empty?
          # content is nil ONLY for a Result built without the field — the code-layer
          # Result unit specs do this; the real paths (#call / #empty_result) always
          # set it. to_a keeps #empty? safe for that spec case.
          vision.nil? && capabilities.empty? && symbols.empty? && content.to_a.empty?
        end
      end

      # @param asker [User, nil] the principal whose per-area access gates the
      #   project-content layer (Plan §4.2). nil ⇒ no content (fail-closed).
      def initialize(chat:, query:, asker: nil, embed_provider: nil)
        @chat           = chat
        @query          = query.to_s.strip
        @organisation   = chat.organisation
        @asker          = asker
        @embed_provider = embed_provider
      end

      # projekt_chat_abbau: one path left. The single-project path ran FOUR layers
      # on every question -- vision (1 row, always), the 5 nearest capabilities, the
      # 10 nearest code symbols, and the content layer -- so every question in the
      # surface carried code context whether it needed it or not, "hallo"
      # included. That is an ACCEPTED loss, recorded in the plan and not rebuilt: the
      # assistant's five code tools return the same citation shapes
      # (Lalabase::Citations.vision / .capability / .symbol), so the sources under an
      # answer are unchanged, and the model decides when to pay for them. What it
      # costs is recall on a question that does not sound like a code question but
      # needs code to answer.
      def call
        return empty_result if @query.empty?

        org_call
      end

      private

      # S3a T3 (Plan §9.1): the org thread runs the CONTENT layer only, across the
      # asker's per-area project reach — the same per-area gate as the
      # single-project path, resolved once per area. The code layers stay
      # deliberately empty: vision is 1:1 per project and symbols hang off a
      # pinned repo; the org thread has neither, and widening them would be a
      # separate decision, not a side effect of this one.
      def org_call
        scope = Lalabase::Tools::Scope.for(chat: @chat, actor: @asker)
        type_map = org_content_projects(scope)
        content = type_map.empty? ? [] : fetch_org_content(embed_query, type_map)
        Result.new(
          vision: nil, capabilities: [], symbols: [],
          content: content,
          citations: build_citations(nil, [], [], content),
          # Through Scope, NOT by hand: the shape grew a `chosen` key in T5 and a
          # second builder is how that key reached only half the answers. The
          # merge in ChatResponseJob picks the FIRST hash on a tie, and this one
          # is passed first -- a hand-built hash here silently outvotes the tool
          # coverage that carries the chip.
          coverage: scope.coverage_with(searched: type_map.values.flatten.uniq.size)
        )
      end

      def embed_query
        Lalabase::QueryEmbedding.embed(@query, @organisation, provider: @embed_provider)
      end

      # Org-wide content layer (S3a T3): same NN search, but the row boundary is a
      # per-TYPE project map instead of one project — each type may only come from
      # the projects whose area the asker reads (Fragment.for_context_map keeps
      # the privacy predicates identical to the single-project scope).
      def fetch_org_content(embedding, type_map)
        return [] if type_map.empty?

        hits = Embeddings::NearestNeighbors.call(
          embeddable_type: 'Fragment', organisation: @organisation,
          query_vector: embedding, limit: CONTENT_TOP_K,
          scope: Fragment.for_context_map(type_map)
        )
        fragments = hits.map(&:record)
        preload_citation_targets(fragments)
        fragments
      end

      # {fragmentable_type => [project_ids]} for the asker, resolved through
      # Tools::Scope — the ONE owner of org-wide reach (active membership, archived
      # projects, per-area ids). A second resolution here is what the T3 second
      # review caught: it skipped the membership check. Fail-closed without an
      # asker; types with no reachable project drop out entirely.
      #
      # This IS the per-area gate now (Plan §4.2): only fragmentable_types whose
      # area the asker may read, and unregistered types are never included
      # (ContentAreaRegistry is the whitelist). The single-project twin it used to
      # mirror went with projekt_chat_abbau.
      def org_content_projects(scope)
        return {} if @asker.nil?

        ContentAreaRegistry.registered_types.each_with_object({}) do |type, map|
          ids = scope.project_ids(area: ContentAreaRegistry.area_for(type))
          map[type] = ids if ids.any?
        end
      end

      # N+1 guard (#6): load the fragmentables + the parents needed for the citation
      # link (Post→ticket, DocumentVersion→document, DocumentationPage→documentation_set,
      # MeetingAnalysis→meeting) in a constant number of queries.
      def preload_citation_targets(fragments)
        ActiveRecord::Associations::Preloader.new(records: fragments, associations: :fragmentable).call
        grouped = fragments.group_by(&:fragmentable_type)
        posts = (grouped['Post'] || []).map(&:fragmentable).compact
        dvs   = (grouped['DocumentVersion'] || []).map(&:fragmentable).compact
        docs  = (grouped['DocumentationPage'] || []).map(&:fragmentable).compact
        analyses = (grouped['MeetingAnalysis'] || []).map(&:fragmentable).compact
        ActiveRecord::Associations::Preloader.new(records: posts, associations: :ticket).call if posts.any?
        ActiveRecord::Associations::Preloader.new(records: dvs, associations: :document).call if dvs.any?
        ActiveRecord::Associations::Preloader.new(records: docs, associations: :documentation_set).call if docs.any?
        # The citation reads project_id via analysis.meeting.project_id (Slice 7b).
        ActiveRecord::Associations::Preloader.new(records: analyses, associations: :meeting).call if analyses.any?
        preload_attachment_parents(grouped)
      end

      # An attachment's citation reads its parent (ticket / post -> ticket) and its
      # prompt label additionally reads the FILENAME, which lives on the blob. Both are
      # preloaded here, or a handful of retrieved files turn into a query each while the
      # prompt is being built.
      def preload_attachment_parents(grouped)
        ticket_docs = (grouped['TicketDocument'] || []).map(&:fragmentable).compact
        post_docs   = (grouped['PostDocument'] || []).map(&:fragmentable).compact
        if ticket_docs.any?
          ActiveRecord::Associations::Preloader.new(
            records: ticket_docs, associations: [:ticket, { ticket_document_file_attachment: :blob }]
          ).call
        end
        return if post_docs.empty?

        ActiveRecord::Associations::Preloader.new(
          records: post_docs, associations: [{ post: :ticket }, { post_document_file_attachment: :blob }]
        ).call
      end

      def build_citations(vision, capabilities, symbols, content)
        cites = []
        cites << Lalabase::Citations.vision(vision) if vision
        capabilities.each { |cap| cites << Lalabase::Citations.capability(cap) }
        symbols.each      { |sym| cites << Lalabase::Citations.symbol(sym) }
        content.each      { |frag| cites << Lalabase::Citations.for_fragment(frag) }
        # Dedup by target (R4): several fragments of the same ticket/note/document
        # collapse to ONE citation. Code-layer ids are unique, so they pass through.
        cites.compact.uniq { |c| [c[:type], c[:id]] }
      end

      def empty_result
        Result.new(vision: nil, capabilities: [], symbols: [], content: [], citations: [])
      end
    end
  end
end
