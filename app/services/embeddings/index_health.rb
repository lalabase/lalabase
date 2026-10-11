# frozen_string_literal: true

# KI-Bereich S2 (doc/ki_bereich_navigation_plan.md §3.3) — the hub's indexing figure,
# cheap enough to ask on the entry page of the area.
module Embeddings
  # Entry point: call
  #
  # The organisation-wide "is my content searchable?" figure, in ONE query.
  #
  # Why not AiSyncStatusService: that one is the read model of the detail PAGE. It
  # loads every project of the organisation and walks every content type per project,
  # each with several counts plus fragment grouping. Correct there, far too expensive
  # for the AI hub, whose whole promise is that the overview costs less than any page
  # under it (doc/ki_bereich_navigation_plan.md §3.3 plus its 2026-08-05 addendum sets the
  # budget at ≤ 9 OWN queries for the whole hub — four counts per content type would blow
  # it on this card alone).
  #
  # So this is a deliberate second reader of the same columns, not a duplicate of the
  # first: it answers only "how much is outstanding and how much failed", org-wide,
  # with no per-project breakdown. §3.5 of the plan calls for exactly one source behind
  # both the hub card and the summary line the Indexierung page gets in S4 — this is it,
  # and since S4 the Indexierung page's headline reads from here rather than deriving a
  # second backlog next to the per-project table it still renders below.
  #
  # Raw SQL on purpose. Nine ActiveRecord relations would be nine round trips, and the
  # UNION ALL below folds them into one. That means acts_as_tenant is NOT in play, so
  # the organisation is bound explicitly on every branch — the one thing to keep right
  # when editing this: a missing organisation_id here leaks another tenant's backlog
  # into this organisation's card.
  class IndexHealth
    # @param space [Hash, nil] the ACTIVE vector space as the provenance triple
    #   {embedding_provider:, embedding_model:, embedding_dims:}, or nil. nil covers
    #   both "not asked for" (the hub) and "not resolvable" (see #active_space) — a
    #   caller that must tell those apart has asked the wrong object; what a surface
    #   can do with either is the same, namely say nothing about the space.
    Result = Struct.new(:pending, :failed, :space, :ai_enabled, keyword_init: true) do
      # "Everything the pipeline was asked to do is done." Both halves, because a
      # backlog of zero with three failures is not a healthy index.
      def clear?
        pending.zero? && failed.zero?
      end

      # ⚠️ `ai_enabled` is load-bearing here, not decoration. A backlog only means work in
      # PROGRESS while a pipeline is allowed to run, and with the opt-in off none of it
      # will ever be embedded — asked without this term, an AI-off organisation reported
      # "Verarbeitung läuft" forever. Measured 2026-08-31: 17 production organisations,
      # 68 records between them, every one of them permanently "outstanding" on a page
      # whose button cannot resolve it.
      #
      # Kept OUT of Embeddings::PendingEmbeddings on purpose: that relation is what
      # Embeddings::ActivationBackfill walks the moment somebody switches AI ON, so it
      # must keep seeing exactly these records. The count is honest, the WORD for it was
      # not. This is a display question, not a selection one.
      def working?
        ai_enabled && pending.positive? && failed.zero?
      end

      # "The pipeline is not allowed to run at all." Surfaces ask this FIRST — over an
      # AI-off organisation neither "alles verarbeitet" nor "Verarbeitung läuft" is a true
      # sentence, and there is no button that changes it.
      def paused?
        !ai_enabled
      end
    end

    # The content types this counts come from Embeddings::ContentTypes — THE list, shared
    # with the reprocess button (PendingEmbeddings) and the sync page (AiSyncStatusService).
    # This file used to carry its own copy: S2 built four sources by mirroring the sync
    # PAGE while the button worked on seven, so the moment S4 hung an ACTION on the figure
    # the page reported "everything processed", hid the button, and a click would still
    # have enqueued jobs for meetings, analyses and documentation pages that nobody was
    # counting. A parity guard then held the two copies together — and the third copy on
    # the sync page had drifted to four types before anyone looked. Now every reader
    # derives from the registry, and index_health_pending_parity_spec.rb proves it by
    # stubbing the list rather than by comparing transcripts.

    def self.call(organisation:, with_space: false)
      new(organisation: organisation, with_space: with_space).call
    end

    # @param with_space [Boolean] also resolve WHICH vector space the counts describe.
    #   Off by default, and the default is the whole point: the hub's budget is nine own
    #   queries for the entire page (§3.3 plus its 2026-08-05 Nachtrag) and it is at nine.
    #   The Indexierung page (S4) asks for it because §3.5 requires it there — "12
    #   ausstehend" stopped being a complete statement the day an organisation could hold
    #   more than one space, and that page has room for the extra read where the hub has
    #   none. One source for both surfaces, two levels of detail, rather than a second
    #   reader growing next to this one.
    def initialize(organisation:, with_space: false)
      @organisation = organisation
      @with_space = with_space
    end

    def call
      row = ActiveRecord::Base.connection.select_one(sanitised_sql)
      Result.new(pending: row['pending'].to_i, failed: row['failed'].to_i,
                 space: @with_space ? active_space : nil,
                 ai_enabled: @organisation.ai_enabled?)
    end

    private

    # The space that SERVES queries, asked through the same authority the read seam
    # uses (Lalabase::Llm::Factory.embedding_space_for with space: :active — the pointer
    # row, falling back to the configured triple). Deriving it from the organisation's
    # embedding_* columns here would name the space being BUILT during a staged switch
    # while the counts describe the one still being read.
    #
    # nil rather than an exception on an unresolvable lane: this is a status page, and
    # the same posture Embeddings::SwitchProgress takes for the same failure. A missing
    # or broken credential is an operator finding (`embeddings:check_alignment` reports
    # it); it must not turn the page that would show the backlog into a 500.
    def active_space
      ::Lalabase::Llm::Factory.embedding_space_for(@organisation, space: :active)
    rescue ::Lalabase::Llm::Provider::Error => e
      Rails.logger.warn("#{self.class}: active embedding space unresolvable for organisation " \
                        "#{@organisation.id} — #{e.class}: #{e.message}")
      nil
    end

    def sanitised_sql
      ActiveRecord::Base.sanitize_sql_array([union_sql, *([@organisation.id] * ContentTypes.entries.size)])
    end

    # COALESCE, not a bare SUM: with no content at all every branch returns zero rows
    # and SUM answers NULL, which would render as an empty card instead of "aktuell".
    def union_sql
      <<~SQL.squish
        SELECT COALESCE(SUM(pending), 0) AS pending, COALESCE(SUM(failed), 0) AS failed
        FROM (#{ContentTypes.entries.map { |entry| branch_sql(entry) }.join(' UNION ALL ')}) AS index_health
      SQL
    end

    # pending = flag not true AND no error; failed = error set. The state atoms are the
    # registry's (one spelling for every reader), the SPLIT is this reader's: a record
    # whose last attempt failed is failed, not outstanding — the button disagrees on
    # purpose and retries it (PendingEmbeddings has no error term).
    def branch_sql(entry)
      table = entry.table
      pending = ContentTypes.flag_pending(table)
      failed = ContentTypes.failed(table)
      <<~SQL.squish
        SELECT
          COUNT(*) FILTER (WHERE #{pending} AND NOT #{failed}) AS pending,
          COUNT(*) FILTER (WHERE #{failed}) AS failed
        FROM #{table} #{entry.join}
        WHERE #{table}.organisation_id = ? AND (#{entry.opt_in})
      SQL
    end
  end
end
