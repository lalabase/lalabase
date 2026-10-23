# frozen_string_literal: true

# app/services/actors/save_meeting_analysis.rb

module Actors
  # Tier 1 actor (BaseActor#call template) for meeting analyses (Gespräche Slice 7a).
  # Three operations, keyed on `id` + params:
  #   - create (id nil): snapshot the chosen prompt (library pick OR free text,
  #     optionally saved to the org library), mark the run pending, and enqueue the
  #     async LLM job after commit.
  #   - rerun (id + params[:rerun]): re-run a failed analysis on its FROZEN snapshot
  #     (mark pending again, re-enqueue) — no new row, no new prompt selection.
  #   - flip (id present): toggle the analysis between private and published.
  #
  # Existing analyses load meeting-scoped via meeting.meeting_analyses (Eng-Review
  # 1A) — the meeting arrives project-verified from the controller, so a foreign
  # id is simply not found.
  #
  # Slice 7b hangs the search/chat embedding wiring off the flip: the embedding
  # enqueue (gated on create_embeddings? + a real content/opt-in change) via
  # #enqueue_jobs, and a SYNCHRONOUS fragment purge on de-index (Entscheidung 5 —
  # a private analysis's PII must leave no retrievable fragment). Unpublishing also
  # clears include_in_search (4A): re-indexing is a deliberate act.
  class SaveMeetingAnalysis < BaseActor
    # Short display title derived from a free-text prompt (first non-blank line).
    DERIVED_TITLE_LIMIT = 80

    def initialize(meeting:, current_user:, params: {}, id: nil)
      super()
      @meeting = meeting
      # The project the caller authorized the write against, before any lock.
      @authorized_project_id = meeting.project_id
      @current_user = current_user
      @params = params
      @id = id
      @analysis = nil
      @enqueue_run = false
    end

    def record
      @analysis
    end

    def perform
      guard_meeting_in_project!
      if @id.blank?
        create_analysis
      elsif boolean(@params[:rerun])
        rerun_analysis
      else
        flip_visibility
      end
    end

    def enqueue_jobs
      enqueue_analysis_run
      enqueue_embedding
    end

    private

    # Enqueue the async LLM run after commit — only for a fresh create/rerun, never for a
    # visibility flip (the actor contract requires the after-commit wrapper, never a bare
    # enqueue).
    def enqueue_analysis_run
      return unless @enqueue_run && @analysis&.persisted?

      enqueue_after_commit do
        Meetings::AnalysisJob.perform_later(analysis_id: @analysis.id)
      end
    end

    # Re-embed after commit, gated on the publish+search opt-in (create_embeddings?) AND a
    # change to the indexed text or the opt-in itself (#231 metering: a no-op flip must not
    # re-embed — every run costs credits). NOTE: plain_text_version is a METHOD, so there is
    # no saved_change_to_plain_text_version? — its dirty state rides on `content`. The
    # service self-guards on a blank plain_text_version and re-checks the opt-in at run time
    # (start + post-run reload, review PR #247), so a purge that lands after this enqueue can
    # never resurrect purged PII. Mirrors SaveMeeting#enqueue_jobs.
    def enqueue_embedding
      return unless @analysis&.create_embeddings?
      return unless @analysis.saved_change_to_content? ||
                    @analysis.saved_change_to_is_private? ||
                    @analysis.saved_change_to_include_in_search?

      enqueue_after_commit do
        EmbeddingProcessingJob.perform_later(
          record_class: MeetingAnalysis,
          record_id: @analysis.id,
          fragment_association: :fragments
        )
      end
    end

    def create_analysis
      title, snapshot, prompt = resolve_prompt
      @analysis = @meeting.meeting_analyses.build(
        organisation: @meeting.organisation,
        creator: @current_user,
        analysis_prompt: prompt,
        prompt_title: title,
        prompt_snapshot: snapshot,
        is_private: true,
        creation_flag: true
      )
      @analysis.save!
      @enqueue_run = true
    end

    # Re-run a failed analysis on its existing frozen snapshot (no re-selection).
    def rerun_analysis
      @analysis = load_analysis!
      raise ActorError, I18n.t('assistant_analysis.no_rerun') if @analysis.source_context.present?

      @analysis.update!(creation_flag: true, creation_error: '')
      @enqueue_run = true
    end

    def flip_visibility
      @analysis = load_analysis!
      attrs = flip_attributes
      raise ActorError, I18n.t('assistant_analysis.private_sources') if !attrs.fetch(:is_private, @analysis.is_private?) && !@analysis.sources_publishable?

      @analysis.update!(attrs)
      purge_fragments_if_deindexed
    end

    # Applies ONLY the flip attributes actually present in params — a search-only toggle
    # must not implicitly publish (a missing is_private would otherwise cast to false and
    # publish a private analysis). The is_private callback re-syncs visible_to_user.
    # 4A: unpublishing (going private) also clears include_in_search, so re-publishing
    # requires a deliberate new search release ("indexing is an explicit act").
    def flip_attributes
      attrs = {}
      # A present-but-uncastable is_private ("" or nil — Boolean#cast returns nil, and permit
      # lets NilClass through as a scalar) must NOT occupy the key: it would hit the NOT NULL
      # column AND shadow the persisted value in the fetch below, so the 4A guard would read
      # nil instead of the real visibility.
      is_private = boolean(@params[:is_private])
      attrs[:is_private] = is_private unless is_private.nil?
      # Same skip as above, and for the same reason: include_in_search is NOT NULL too.
      # A present-but-uncastable value ("" or nil) used to be written straight through,
      # and on an already-published analysis 4A does not catch it, so the update hit the
      # constraint. In production handle_unexpected_error turns that into a failure Result
      # carrying the raw PG text, which the controller then rendered as a flash.
      include_in_search = boolean(@params[:include_in_search])
      attrs[:include_in_search] = include_in_search unless include_in_search.nil?
      enforce_4a_search_release!(attrs)
      attrs
    end

    # 4A ("a private analysis is NEVER search-released") enforced in the WRITE SEAM — here,
    # neither by a DB constraint nor by a model validation. Forces the search release off
    # whenever the EFFECTIVE visibility is private, so a crafted search-only PATCH
    # { include_in_search: true } on an already-private analysis (is_private absent from the
    # params) cannot store private + searchable.
    #
    # "Effective" = this flip's is_private if it carries one, else the persisted value. Read it
    # from `attrs` (already CAST), never from @params: "false" is truthy in Ruby, so a
    # raw-params fetch would silently swallow the legitimate combined publish+release flip.
    #
    # Why NOT at the data layer, although that would be stronger: the fail-closed specs
    # construct exactly this inconsistent state ON PURPOSE, to prove that nothing leaks out of
    # it (pending_embeddings_spec, combined_search_service_privacy_spec,
    # retriever_content_spec). A CHECK constraint would make those proofs unbuildable, and they
    # are worth more than the constraint — every retrieval/embed gate is already fail-closed on
    # is_private (create_embeddings? is a conjunction), so this method is defense-in-depth for a
    # FUTURE consumer that reads include_in_search alone. That trade-off is pinned by the spec
    # "4A is a write-seam rule, not a data constraint (deliberate)".
    def enforce_4a_search_release!(attrs)
      attrs[:include_in_search] = false if attrs.fetch(:is_private, @analysis.is_private?)
    end

    # Leak-Schutz (Entscheidung 5): a de-indexed analysis — private, OR search-released
    # off, OR no content to index — must leave NO retrievable fragment. Runs SYNCHRONOUSLY
    # inside the actor transaction (unlike Note, which keeps stale fragments on opt-out).
    # Also resets the two status columns to nil ("never attempted") so a later re-publish
    # re-embeds instead of being skipped by a lingering flag = true in PendingEmbeddings.
    # Mirrors Actors::SaveMeeting#purge_fragments_if_deindexed.
    def purge_fragments_if_deindexed
      return if @analysis.create_embeddings? && @analysis.plain_text_version.present?

      # Sidecar purge (embedding v2 PR 2): remove the fragments' content_embeddings
      # rows BEFORE the callback-free delete_all removes the fragments (the subselect
      # needs them), inside this same actor transaction. Mirrors SaveMeeting — a
      # de-indexed analysis's PII must leave no retrievable trace (GC ships in PR 3).
      ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: @analysis.fragments.select(:id))
      @analysis.fragments.delete_all
      # deliberate: reset the two status
      # columns only, bypassing callbacks (no visible_to recompute, no broadcast).
      @analysis.update_columns(embeddings_creation_flag: nil, embedding_creation_error: nil)
    end

    # Meeting-scoped (1A): a foreign/other-meeting analysis id is simply not found.
    #
    # `lock` is what makes the 4A guard hold under concurrency, not merely under
    # serialised requests. The guard reads the PERSISTED visibility out of this record;
    # without FOR UPDATE a second transaction can flip is_private between this SELECT and
    # the UPDATE below, and this run then writes its search release onto an analysis that
    # has meanwhile become private. `perform` already runs inside BaseActor's transaction,
    # so the lock lives exactly as long as it must.
    # Actors::MoveMeeting holds the meeting's row lock while it moves it and
    # checks the published analyses. Under the same lock a meeting that moved
    # meanwhile is gone from the project this write was authorized against,
    # so nothing is created, rerun or published there.
    def guard_meeting_in_project!
      @meeting.lock!
      return if @meeting.project_id == @authorized_project_id

      raise ActorError, I18n.t('services.meetings.analysis.not_found')
    end

    def load_analysis!
      @meeting.meeting_analyses.lock.find_by(id: @id) ||
        raise(ActorError, I18n.t('services.meetings.analysis.not_found'))
    end

    # Returns [prompt_title, prompt_snapshot, analysis_prompt|nil]. A library pick
    # wins; otherwise the free-text prompt, optionally saved to the org library.
    def resolve_prompt
      if @params[:analysis_prompt_id].present?
        prompt = AnalysisPrompt.where(organisation: @meeting.organisation, id: @params[:analysis_prompt_id]).first
        raise ActorError, I18n.t('services.meetings.analysis.prompt_not_found') if prompt.nil?

        [prompt.title, prompt.prompt_text, prompt]
      else
        text = @params[:prompt_text].to_s.strip
        raise ActorError, I18n.t('services.meetings.analysis.prompt_blank') if text.blank?

        title = derived_title(text)
        prompt = save_template? ? create_template(title, text) : nil
        [title, text, prompt]
      end
    end

    def save_template?
      boolean(@params[:save_as_template])
    end

    def create_template(title, text)
      AnalysisPrompt.create!(
        organisation: @meeting.organisation,
        creator: @current_user,
        title: @params[:template_title].presence || title,
        prompt_text: text
      )
    end

    def derived_title(text)
      (text.lines.map(&:strip).find(&:present?) || text.strip).truncate(DERIVED_TITLE_LIMIT)
    end

    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
