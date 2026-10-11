# frozen_string_literal: true

module Lalabase
  module ProjectRag
    # Maps a fragmentable_type to the project-permission AREA that gates it.
    #
    # Backbone of the content-RAG access model (Plan §3.2): the Retriever iterates
    # this registry and surfaces a type ONLY when ProjectPolicy#area_access?(area,
    # :read) holds for the asker. Fail-closed: an unregistered type returns nil and
    # is excluded — a new embeddable type can never leak in by default.
    #
    # The area symbols MUST match what ProjectPolicy#area_access? understands
    # (ProjectPermission columns: tickets/notes/documents, plus the time_sessions
    # special-case). `Post` maps to :tickets, mirroring
    # AccessCheck::ProjectAccessService#normalize_area (posts → tickets) and the
    # fact that a Post is a ticket comment.
    #
    # Guard (content_area_registry_spec): every type actually embedded into
    # `fragments` MUST be registered here — otherwise a newly-embedded type would
    # either leak silently (surfaced ungated) or be swallowed.
    #
    # ⚠️ That guard now DERIVES its list from Embeddings::PendingEmbeddings instead of
    # carrying its own copy. It used to transcribe the seven types, and the transcript
    # was missing the same two entries this map was (TicketDocument, PostDocument) — so
    # it stayed green over exactly the gap it exists to catch, for months. A guard that
    # repeats the thing it guards proves nothing.
    #
    # Future (Plan §11): `'TimeSession' => :time_sessions` is a one-line addition HERE,
    # but NOT a one-line feature. area_access?(:time_sessions, …) has a special branch
    # that FALLS THROUGH to ProjectAccessService#can? when the user has no
    # time_session_permissions row — so its gate semantics differ from
    # tickets/notes/documents (which go straight through can?). Activating TimeSessions
    # must test that fall-through explicitly, or content could surface for a user the
    # fall-through unexpectedly grants.
    #
    # ⚠️ Adding/removing a content type is a CROSS-CUTTING change. Several places encode
    # "the content types", each owning a DIFFERENT concern — deliberately kept separate
    # (one shared abstraction would be cleverer but harder to read), so keep them in sync.
    #
    # Retrieval + display side — a forgotten entry here fails CLOSED (excluded at #1/#4,
    # or a red R1/label spec), never a silent leak:
    #   1. AREA_BY_TYPE (here)                        — type → gating area
    #   2. Lalabase::Citations.for_fragment + TYPES   — type → citation shape / link fields
    #   3. ProjectRag::PromptBuilder#content_label    — type → prompt label
    #   4. Fragment::FRAGMENTABLE_PROJECT_JOINS        — type → project_id join path
    #   4b. Fragment::TYPE_CONTEXT_PREDICATES          — type → privacy predicate BOTH context
    #      scopes are built from (for_project_context / for_context_map, S3a T3); a
    #      registered type without one vanishes from retrieval in both paths (guard below)
    #   5. Neo::Chat::CitationListComponent           — ICON_MAP + label_for/link_for branch
    # Ingestion side — a forgotten entry here means the type is never EMBEDDED, so it
    # cannot leak; it just silently fails to ground:
    # ⚠️ NOT in sync for the two attachment types, on purpose (04.09.2026):
    # CombinedSearchService is the in-app SEARCH, a different surface with its own result
    # rendering, and it keeps its own WHERE (see Fragment::FRAGMENTABLE_PROJECT_JOINS). It
    # was left out of the attachment registration so this change stays one surface wide.
    # Whoever adds it there has a rendering question to answer first, not only a predicate.
    #
    #   6. Embeddings::ContentTypes — THE type list with its per-type opt-in rules, from
    #      which Embeddings::PendingEmbeddings derives the "still pending" relations that
    #      EmbeddingReprocessingService (org re-index) AND PendingBacklog (monthly
    #      catch-up) both consume, and Embeddings::IndexHealth / AiSyncStatusService
    #      derive their counts; PLUS the write path that enqueues
    #      EmbeddingProcessingJob on change (the owner's actor/save — Actors::SaveMeeting
    #      for meetings, gated on create_embeddings — or DocumentationSyncJob for doc pages).
    # The guard spec here pins #1 against the embedded-type list; Citations' own header
    # carries the shape/label checklist. Authoritative six-point list:
    # doc/documentation_feature_plan.md §3b.
    module ContentAreaRegistry
      AREA_BY_TYPE = {
        'Ticket' => :tickets,
        'Post' => :tickets,
        'Note' => :notes,
        'DocumentVersion' => :documents,
        # External repo docs (Slice 3). :documentation is a real ProjectPermission
        # column, so the retriever's per-area gate AND the render-gate both enforce
        # the "must hold :documentation read" half of the double-gate for free.
        'DocumentationPage' => :documentation,
        # Conversations (Gespräche Slice 6). :meetings is a real ProjectPermission
        # column, so the per-area gate + render-gate enforce meetings-read for free.
        # UNLIKE the others, a meeting is embedded ONLY on an explicit per-meeting
        # opt-in (create_embeddings) — that PII gate lives in the ingestion path
        # (Fragment#for_project_context + CombinedSearchService), not in this map.
        'Meeting' => :meetings,
        # Meeting analyses (Gespräche Slice 7b) share the SAME :meetings gate as their
        # meeting. Embedded ONLY when published AND search-released (is_private = FALSE
        # AND include_in_search = TRUE) — that per-analysis PII gate lives in the
        # ingestion path (Fragment#for_project_context + CombinedSearchService), not here.
        'MeetingAnalysis' => :meetings,
        # Attachments (04.09.2026). They were embedded from the day the upload path was
        # built and registered NOWHERE, so the vector existed and no query could return
        # it: a PDF on a ticket was unreachable for the assistant and for the search.
        #
        # :tickets for both, because an attachment must never be the way AROUND the read
        # right of the object it hangs on. A comment attachment additionally inherits its
        # comment's privacy — that half is a row filter and lives, like the meeting ones,
        # in the ingestion path (Fragment::TYPE_CONTEXT_PREDICATES), not in this map.
        'TicketDocument' => :tickets,
        'PostDocument' => :tickets
      }.freeze

      module_function

      # @return [Symbol, nil] the gating area, or nil for an unregistered type (fail-closed).
      def area_for(fragmentable_type)
        AREA_BY_TYPE[fragmentable_type.to_s]
      end

      # @return [Array<String>] the registered fragmentable_type names.
      def registered_types
        AREA_BY_TYPE.keys
      end
    end
  end
end
