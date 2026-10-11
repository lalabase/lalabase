# frozen_string_literal: true

# AI analyses of a meeting with a selectable prompt (Gespräche Slice 7a). Nested
# under the meeting: create runs the async LLM job, update flips visibility
# (publish/unpublish), destroy removes one. Visibility is per-creator (Post
# pattern) — the list is filtered to what the current user may see BEFORE it
# reaches the section partial, which stays free of request-only helpers (E21).
#
# create mirrors meetings_controller#create_summary: Pundit authorize, the D11
# one-run-per-meeting idempotency guard, a blank-source guard and the ai_feature_available?
# recheck (defence in depth on top of the view gate). Since #817 creation belongs to
# the assistant, so create and rerun first require its gate and answer 403 without it:
# an old open page must not keep a paid run alive for someone the assistant excludes.
module Organisations
  class MeetingAnalysesController < Organisations::BaseController
    include ProjectController
    include MeetingAnalysesStreams

    before_action :set_meeting
    before_action :set_analysis, only: %i[update destroy]

    def create
      authorize @meeting.meeting_analyses.build, :create?
      return respond_hint('flash.meeting_analyses.assistant_unavailable', status: :forbidden) unless assistant_creation_allowed?

      # D11 idempotency: one analysis run per meeting at a time (double-click /
      # second tab / crafted POST must not enqueue another paid LLM job).
      return respond_hint('flash.meeting_analyses.already_running') if @meeting.analysis_generation_running?
      return respond_hint('flash.meeting_analyses.no_content') if @meeting.summary_source.blank?
      return respond_hint('flash.meeting_analyses.ai_unavailable') unless ai_feature_available?

      result = Actors::SaveMeetingAnalysis.call(meeting: @meeting, params: create_params, current_user: current_user)
      if result.success?
        # Kept for transition compatibility with an already-open legacy form. The
        # removed compose surface is never rendered back into a current page.
        respond_section('flash.meeting_analyses.started')
      else
        respond_error(error_message_for(result))
      end
    end

    def update
      authorize @analysis, :update?

      return rerun if rerun_requested?

      # D11: a publish/unpublish flip while the run is generating is rejected — a
      # flip would otherwise bump updated_at and extend the stale window.
      return respond_hint('flash.meeting_analyses.flip_running') if @analysis.generation_running?

      result = Actors::SaveMeetingAnalysis.call(meeting: @meeting, id: @analysis.id,
                                                params: flip_params, current_user: current_user)
      if result.success?
        respond_section(flip_flash_key)
      else
        respond_error(error_message_for(result))
      end
    end

    def destroy
      authorize @analysis, :destroy?

      @analysis.destroy
      respond_section(params[:surface] == 'compose' ? 'flash.meeting_analyses.discarded' : 'flash.meeting_analyses.deleted')
    end

    # Transitional response for an old page that requests its lazy desktop lane
    # during a rolling deploy. It contains no legacy composer and starts no work.
    def lane
      authorize @meeting, :show?
      render :lane, layout: false
    end

    private

    # Retry a failed analysis on its frozen snapshot. Same gates as create
    # (assistant, D11 one-run-per-meeting, blank source, AI available) since it
    # enqueues a paid LLM job. The row hides its retry button without the assistant
    # (can_rerun), this is the server half for a page rendered before that.
    def rerun
      return respond_hint('flash.meeting_analyses.assistant_unavailable', status: :forbidden) unless assistant_creation_allowed?
      return respond_hint('flash.meeting_analyses.already_running') if @meeting.analysis_generation_running?
      return respond_hint('flash.meeting_analyses.no_content') if @meeting.summary_source.blank?
      return respond_hint('flash.meeting_analyses.ai_unavailable') unless ai_feature_available?

      result = Actors::SaveMeetingAnalysis.call(meeting: @meeting, id: @analysis.id,
                                                params: { rerun: true }, current_user: current_user)
      result.success? ? respond_section('flash.meeting_analyses.started') : respond_error(error_message_for(result))
    end

    def rerun_requested?
      ActiveModel::Type::Boolean.new.cast(params.dig(:meeting_analysis, :rerun))
    end

    # ProjectController derives the area from the controller name
    # ("meeting_analyses" → :meeting_analysis, which is no real area and denies
    # everyone). Analyses live in the :meetings area — writing one needs meetings-write.
    def determine_access_area
      :meetings
    end

    def set_meeting
      # Scoped to @project.meetings: a foreign-project/tenant meeting id 404s.
      @meeting = @project.meetings.find(params[:meeting_id])
    end

    def set_analysis
      # 1A: meeting-scoped, never org-wide — a foreign analysis id 404s.
      @analysis = @meeting.meeting_analyses.find(params[:id])
    end

    # R2: asks the FEATURE, not a provider — Meetings::AnalysisService is the seam
    # registered for :meeting_analysis, so this gate and Factory.for_feature read
    # the same row. Was ai_available_for_chat?, before that
    # ai_available?(BaseLlmService::PROVIDER) — a constant that pinned 'openai' and
    # therefore 403'd every org on another provider.
    # Not named ai_available? (R5): that is Organisation's low-level API, which
    # feature_registry_guard_spec keeps out of controllers — a local method of the
    # same name is indistinguishable from a call to it in a source guard.
    def ai_feature_available?
      current_organisation.ai_available_for?(:meeting_analysis).available?
    end

    def assistant_creation_allowed?
      ChatPolicy.assistant_gate_open?(current_user, current_organisation)
    end

    def create_params
      params.require(:meeting_analysis).permit(:analysis_prompt_id, :prompt_text, :save_as_template, :template_title)
    end

    # publish/unpublish (is_private) and/or the search release (include_in_search, Slice
    # 7b). The actor applies only the keys actually present, so a search-only toggle never
    # implicitly publishes.
    def flip_params
      params.require(:meeting_analysis).permit(:is_private, :include_in_search)
    end

    # A search-only toggle (include_in_search present, is_private absent) reports the
    # search state; a publish/unpublish flip reports the visibility state.
    def flip_flash_key
      submitted = flip_params
      reloaded = @analysis.reload
      if submitted.key?(:include_in_search) && !submitted.key?(:is_private)
        reloaded.include_in_search? ? 'flash.meeting_analyses.search_enabled' : 'flash.meeting_analyses.search_disabled'
      else
        reloaded.private? ? 'flash.meeting_analyses.unpublished' : 'flash.meeting_analyses.published'
      end
    end

    def respond_section(flash_key)
      streams = [results_replace, flash_stream(flash_key)]
      respond_to do |format|
        format.turbo_stream { render turbo_stream: streams }
        format.html { redirect_to_meeting(notice: t(flash_key)) }
      end
    end

    # Friendly, no-enqueue response for the guarded cases (running / blank / AI
    # unavailable). :unprocessable_entity so Turbo does not treat it as navigation;
    # :forbidden for the assistant gate, which is a permission and not a state.
    def respond_hint(flash_key, status: :unprocessable_entity)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: flash_stream(flash_key, type: :alert), status: status }
        format.html { redirect_to_meeting(alert: t(flash_key)) }
      end
    end

    # An actor domain failure — surface its (already localised) message.
    # The message a failed actor result may show. :internal_error carries the raw exception
    # text (a PG::NotNullViolation prints the whole failing row), and that must never reach
    # a flash. Same masking as TimeSessionGroupsController.
    def error_message_for(result)
      return t('flash.meeting_analyses.error') if result.code == :internal_error

      result.errors.first
    end

    def respond_error(message)
      message = message.presence || t('flash.meeting_analyses.error')
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.prepend('flash', partial: 'layouts/flash',
                                                             locals: { flash: { alert: message } }),
                 status: :unprocessable_entity
        end
        format.html { redirect_to_meeting(alert: message) }
      end
    end

    def redirect_to_meeting(**flash_opts)
      redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_id: @meeting.id),
                  **flash_opts
    end
  end
end
