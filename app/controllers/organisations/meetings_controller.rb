# frozen_string_literal: true

# Meetings (Gespräche) master-detail — Slice 1a. Mirrors the Notes/Knowledge
# master-detail UX (list left, detail in a Turbo frame), but as a single-model,
# self-contained page. Project scoping + area authorization come from
# ProjectController (redirect on denial); every non-index action additionally
# runs Pundit `authorize` so BaseController's verify_authorized is satisfied.
module Organisations
  class MeetingsController < Organisations::BaseController
    include ProjectController
    include ViewportSwitchable
    include AdHocFilterable
    include Pageable
    include MeetingList

    # edit/update included so the detail-frame re-render after a save keeps the right
    # viewport: the edit link + form carry viewport so the round-trip preserves it.
    # Since #817 _meeting_show has no viewport branch of its own any more.
    before_action :set_viewport_mode, only: %i[index show new create edit update]
    before_action :set_meeting, only: %i[show edit update destroy create_summary toggle_search]

    # The same literal ids live in the meetings views and the shared list-row
    # configuration — keep them in sync when renaming.
    DETAIL_FRAME_ID = 'meeting_display_frame'
    LIST_FRAME_ID = 'meetings_results'

    # The org-wide list ("Alle Meetings") creates through a modal that hosts this
    # controller's own `new` form in a frame of its own. Both ids are declared by the
    # partial that carries the frame — meetings_overview/_new_meeting_modal.html.erb
    # and _results.html.erb — the same "keep them in sync" rule as the two above.
    # The filter bar of that page targets OVERVIEW_LIST_FRAME_ID too.
    # OVERVIEW_LIST_FRAME_ID is REPLACED on a save, so its partial has to bring the
    # <turbo-frame> itself; a frameless partial would delete the frame and every
    # later stream to it would vanish without a word.
    MODAL_FRAME_ID = 'meeting_modal_form'
    OVERVIEW_LIST_FRAME_ID = 'meetings_overview_results'

    # Third place the Stimulus identifier "meeting-modal" appears (with the modal
    # partial's data-controller and the importmap pin): the cancel button inside the
    # form has to close the modal, and the form is rendered from here. Renaming the
    # controller means renaming it here too — nothing fails loudly otherwise, the
    # button just stops working.
    MODAL_CANCEL_ACTION = 'click->meeting-modal#close'

    # Marks a save that came from that modal. The overview page has neither
    # LIST_FRAME_ID nor DETAIL_FRAME_ID, and Turbo drops a stream whose target is
    # missing WITHOUT a word, so the usual success response would look like nothing
    # happened. Same mechanism as the Zeiten form's `context` field.
    OVERVIEW_MODAL_CONTEXT = 'overview_modal'

    # The list renders only these columns (_meeting_row: title, date, duration).
    # Selecting full rows would de-TOAST notes/transcript/plain_text_version (up to
    # ~1 MB each) for every row on every list render — the detail pane loads its
    # full row separately (find_selected_meeting) and the toggle stream reloads
    # before rendering the search badge, so neither depends on this narrow select.
    LIST_COLUMNS = Meetings::ListQuery::LIST_COLUMNS

    # Payload cap for detect_participants (Eng-Review D5): deliberately tighter
    # than the 1 MB save-path limit (Meeting::MAX_CONTENT_BYTES) — a 2h
    # transcript is ~100–200 KB, and the cap keeps the flat per-call credit
    # price of the participant_detection action honest.
    MAX_DETECT_BYTES = 200.kilobytes

    # Service status → services.meetings.participant_detection.* message key.
    # Unknown/unexpected statuses fall back to generic_error (fetch fallback).
    DETECTION_ERROR_KEYS = {
      ai_disabled: 'ai_disabled',
      not_configured: 'not_configured',
      invalid_key: 'invalid_key',
      quota_exceeded: 'quota_exceeded',
      parse_error: 'parse_error'
    }.freeze

    def index
      @meetings = filtered_meetings
      if turbo_frame_request? && request.headers['Turbo-Frame'] == LIST_FRAME_ID
        render partial: 'organisations/meetings/meetings_results', locals: { meetings: @meetings, selected_meeting: nil }
        return
      end
      if turbo_frame_request? && request.headers['Turbo-Frame'] == "#{LIST_FRAME_ID}_sentence"
        render partial: 'organisations/meetings/list_head'
        return
      end
      @selected_meeting = find_selected_meeting(params[:meeting_id]) if params[:meeting_id].present?
      new_meeting_requested = @selected_meeting.nil? && params[:new] == 'meeting' &&
                              policy(@project).area_access?(:meetings, :write)
      @new_meeting = @project.meetings.build(occurred_at: Time.current) if new_meeting_requested
      MeetingTicketSuggestionRun.recover_for_meeting!(@selected_meeting)
      # The claim hint (Nachtrag) is rendered lazily via the meeting_claim_matches
      # helper, so every :index render path shows it and the turbo-frame detail path
      # pays no query — nothing to set up here.
    end

    def show
      authorize @meeting, :show?
      MeetingTicketSuggestionRun.recover_for_meeting!(@meeting)

      if turbo_frame_request? && params[:frame] == 'content'
        render_detail_frame('organisations/meetings/meeting_show', @meeting)
        return
      end

      # Standalone visit (e.g. after create / bookmarked URL): render the full
      # master-detail with this meeting selected.
      @meetings = filtered_meetings
      @selected_meeting = @meeting
      render :index
    end

    def new
      @meeting = @project.meetings.build(occurred_at: Time.current)
      authorize @meeting, :create?

      if turbo_frame_request?
        # Two frames ask for this form: the detail pane of the project page, and the
        # modal on the org-wide list. Same partial, different wrapper and different
        # idea of what "cancel" and "saved" mean.
        case params[:frame]
        when 'content'
          render_detail_frame('organisations/meetings/meeting_new_for_frame', @meeting)
          return
        when 'modal'
          render_modal_frame(@meeting)
          return
        end
      end

      # The list header normally opens the form in the desktop detail frame. On a
      # phone that frame is absent from the list DOM, so the top-level request turns
      # the form into an explicit index-page state while retaining active filters.
      if params[:frame] == 'content'
        redirect_to organisation_project_meetings_path(
          @current_organisation,
          @project,
          request.query_parameters.except('frame', 'frame_id', 'format').merge(new: 'meeting')
        )
      else
        @meetings = filtered_meetings
        render :index
      end
    end

    def create
      authorize @project.meetings.build, :create?

      actor = Actors::SaveMeeting.new(project: @project, params: meeting_params, current_user: current_user)
      result = actor.call
      @meeting = actor.record

      if result.success?
        respond_to do |format|
          format.turbo_stream { render turbo_stream: created_streams(@meeting) }
          format.html do
            # Without JavaScript the modal is a plain form post. A save that started
            # on "Alle Meetings" belongs back there, not in the project's own
            # master-detail — the same rule the turbo_stream branch follows.
            if overview_modal?
              redirect_to organisation_meetings_path(@current_organisation, meeting_index_query), notice: t('flash.meetings.created')
            else
              redirect_to organisation_project_meetings_path(
                @current_organisation,
                @project,
                meeting_index_query.merge(meeting_id: @meeting.id)
              ),
                          notice: t('flash.meetings.created')
            end
          end
        end
      elsif overview_modal?
        render_modal_frame_with_errors(@meeting)
      else
        render_form_with_errors('organisations/meetings/meeting_new_for_frame')
      end
    end

    def edit
      authorize @meeting, :update?

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update(detail_frame_id,
                                                   partial: 'organisations/meetings/meeting_edit',
                                                   locals: { meeting: @meeting, detail_frame_id: detail_frame_id })
        end
        format.html do
          redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query.merge(meeting_id: @meeting.id))
        end
      end
    end

    def update
      authorize @meeting, :update?

      actor = Actors::SaveMeeting.new(project: @project, params: meeting_params, id: @meeting.id, current_user: current_user)
      result = actor.call
      @meeting = actor.record

      if result.success?
        respond_to do |format|
          format.turbo_stream { render turbo_stream: saved_streams(@meeting, 'flash.meetings.updated') }
          format.html do
            redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query.merge(meeting_id: @meeting.id)),
                        notice: t('flash.meetings.updated')
          end
        end
      elsif @meeting.nil?
        # Race: the meeting was deleted between set_meeting and the actor's own
        # lookup. Rendering the form with a nil meeting would 500; send the user
        # back to the (refreshed) list instead.
        redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query),
                    alert: t('flash.meetings.not_found')
      else
        render_form_with_errors('organisations/meetings/meeting_edit')
      end
    end

    def destroy
      authorize @meeting, :destroy?

      if @meeting.destroy
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: [
              list_stream(selected: nil),
              turbo_stream.update(detail_frame_id, partial: 'organisations/meetings/meeting_placeholder'),
              flash_stream('flash.meetings.deleted')
            ]
          end
          format.html { redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query), notice: t('flash.meetings.deleted') }
        end
      else
        redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query.merge(meeting_id: @meeting.id)),
                    alert: t('flash.meetings.delete_error')
      end
    rescue StandardError => e
      # Full details go to the log only — exception messages can carry internals
      # (constraint names, model state) that must not reach the user's flash.
      Rails.logger.error "Error deleting meeting #{@meeting&.id}: #{e.class}: #{e.message}"
      redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query),
                  alert: t('flash.meetings.delete_error')
    end

    # POST /projects/:project_id/meetings/:id/create_summary
    # Enqueues the async AI summary (Slice 4). Write-gated; needs content
    # (transcript or notes) AND a usable AI config — both are also enforced in the
    # view gate, re-checked here as defence in depth against a crafted POST.
    def create_summary
      authorize @meeting, :update?

      # Idempotency guard (review #235): while a generation is running, a second
      # POST (double click, second tab, crafted request) must not enqueue another
      # paid LLM job. Staleness-aware — a stuck flag self-heals after the window
      # (Meeting::SUMMARY_STALE_AFTER), so this guard can never brick the feature.
      return respond_hint('flash.meetings.summary_already_running') if @meeting.summary_generation_running?
      return respond_hint('flash.meetings.summary_no_content') if @meeting.summary_source.blank?

      # R2: asks the FEATURE, not a provider — Meetings::SummaryService is the seam
      # behind :meeting_summary, so gate and Factory.for_feature read the same
      # registry row and cannot drift (was ai_available_for_chat?, before that
      # ai_available?(SummaryService::PROVIDER)).
      summary_available = current_organisation.ai_available_for?(:meeting_summary).available?
      return respond_hint('flash.meetings.summary_ai_unavailable') unless summary_available

      # Pending flag → the section shows "wird erstellt…"; the job clears it on
      # completion and the after_update_commit broadcast pushes the final state.
      @meeting.update!(summary_creation_flag: true, summary_creation_error: '')
      Meetings::SummaryJob.perform_later(meeting_id: @meeting.id)

      respond_to do |format|
        format.turbo_stream { render turbo_stream: summary_section_stream(@meeting) }
        format.html do
          redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query.merge(meeting_id: @meeting.id)),
                      notice: t('flash.meetings.summary_started')
        end
      end
    end

    # POST /projects/:project_id/meetings/:id/toggle_search
    # One-click search & chat release flip (Meeting-Such-Status): flips the
    # per-meeting create_embeddings opt-in WITHOUT the edit form. Runs through
    # Actors::SaveMeeting on purpose — only the actor enqueues the embedding
    # job on release and synchronously purges the fragments on de-index (PII).
    # Write-gated like create_summary; the content guard mirrors the form's
    # disabled toggle (defence in depth against a crafted POST).
    def toggle_search
      authorize @meeting, :update?

      new_value = ActiveModel::Type::Boolean.new.cast(params[:create_embeddings])
      return respond_hint('flash.meetings.search_no_content') if new_value && @meeting.plain_text_version.blank?

      actor = Actors::SaveMeeting.new(project: @project, params: { create_embeddings: new_value },
                                      id: @meeting.id, current_user: current_user)
      result = actor.call

      if result.success?
        flash_key = new_value ? 'flash.meetings.search_enabled' : 'flash.meetings.search_disabled'
        respond_to do |format|
          format.turbo_stream { render turbo_stream: search_status_stream(@meeting, flash_key) }
          format.html do
            redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query.merge(meeting_id: @meeting.id)),
                        notice: t(flash_key)
          end
        end
      else
        respond_hint('flash.meetings.search_toggle_error')
      end
    end

    # POST /projects/:project_id/meetings/detect_participants
    # LLM leg of the participant detection (Slice 5, plan decision 12): runs
    # BEFORE save on the flat `transcript` param — no persisted meeting, so
    # tenant/project scoping comes solely from @project + the write policy.
    # Gate order (plan §5): Pundit write gate → 403 AI gate (ai_available?
    # recheck — 403 is reserved for this case) → 422 payload/blank guards →
    # service. Every service failure (LLM/quota/config/parse) maps to ONE
    # readable 422 JSON error — the fetch client only needs the message; 429
    # comes from the Rack::Attack throttle in front of all of this.
    def detect_participants
      # Instance-shaped authorize so MeetingPolicy#project_policy sees
      # record.project (same pattern as create).
      authorize @project.meetings.build, :detect_participants?

      # R2: the feature behind this action is :meeting_participant_detection
      # (seam Meetings::ParticipantDetectionService). Was ai_available_for_chat?,
      # before that ai_available?('openai') — which 403'd every non-OpenAI org
      # although the routing below had already been corrected.
      unless @current_organisation.ai_available_for?(:meeting_participant_detection).available?
        return render json: { error: t('services.meetings.participant_detection.ai_unavailable') },
                      status: :forbidden
      end

      transcript = params[:transcript].to_s
      if transcript.bytesize > MAX_DETECT_BYTES
        return render json: { error: t('services.meetings.participant_detection.too_large',
                                       max_kb: MAX_DETECT_BYTES / 1.kilobyte) },
                      status: :unprocessable_content
      end
      if transcript.blank?
        return render json: { error: t('services.meetings.participant_detection.empty') },
                      status: :unprocessable_content
      end

      result = Meetings::ParticipantDetectionService.call(
        organisation: @current_organisation, transcript: transcript, user: current_user
      )

      if result.success?
        render json: { participants: result.participants.map { |name| { display_name: name } } }
      else
        key = DETECTION_ERROR_KEYS.fetch(result.status, 'generic_error')
        render json: { error: t("services.meetings.participant_detection.#{key}") },
               status: :unprocessable_content
      end
    end

    # Render-ready <option> list for the participant SlimSelect field (replaces the
    # former participant_suggestions JSON endpoint — the options are server-rendered
    # like the ticket-assignee field). Exposed to the form partial.
    helper_method :meeting_participant_options

    private

    # Ordered options for the participant <select multiple>. Union of:
    #   - internal project members  → value "user:<uuid>", selected when linked
    #   - linked participants whose user is NOT a project member (org_member) so an
    #     edit save preserves the link instead of silently dropping the option
    #   - external names (suggestions from readable meetings ∪ this meeting's own
    #     external participants), deduped by normalized_name so the field never
    #     offers "Jörg" AND "Joerg" (which would crash the save on the unique index)
    # Each option: { value:, label:, type: (:member|:external), selected: }.
    def meeting_participant_options(meeting)
      participants = meeting.meeting_participants.to_a
      selected_user_ids = participants.filter_map(&:user_id).to_set
      selected_ext_names = participants.reject { |p| p.user_id.present? }.map(&:display_name)
      selected_ext_norms = selected_ext_names.map { |n| MeetingParticipant.normalize_name(n) }.to_set

      options = []
      seen_user_ids = Set.new

      internal_participant_suggestions.each do |s|
        seen_user_ids << s[:user_id]
        options << { value: "user:#{s[:user_id]}", label: s[:display_name], type: :member,
                     selected: selected_user_ids.include?(s[:user_id]) }
      end

      participants.each do |p|
        next if p.user_id.blank? || seen_user_ids.include?(p.user_id)

        seen_user_ids << p.user_id
        options << { value: "user:#{p.user_id}", label: p.display_name, type: :member, selected: true }
      end

      seen_ext = Set.new
      (external_participant_suggestions.map { |s| s[:display_name] } + selected_ext_names).each do |name|
        norm = MeetingParticipant.normalize_name(name)
        next if seen_ext.include?(norm)

        seen_ext << norm
        options << { value: name, label: name, type: :external, selected: selected_ext_norms.include?(norm) }
      end

      options
    end

    # Internal autocomplete source: everyone who may READ this project's meetings
    # (whether or not already a participant), used to build the member <option>s above.
    # Canonical source = Project#users_with_access(:read, :meetings) — org admins,
    # global-role users AND direct ProjectPermissions — filtered to active members,
    # exactly like the ticket-assignee picker (TicketsHelper#assignable_users_for).
    # NOT @project.permitted_users: that is ONLY direct ProjectPermission rows, so
    # members with access via org-admin / a global role (including the org owner)
    # were never suggested.
    def internal_participant_suggestions
      User.where(id: @project.users_with_access(:read, :meetings)
                             .where(id: @project.organisation.active_users.select(:id))
                             .ids)
          .order(:last_name, :first_name)
          .map { |u| { display_name: u.display_name, user_id: u.id } }
    end

    def external_participant_suggestions
      project_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        current_user, @current_organisation, action: :read, area: :meetings
      )
      return [] if project_ids.blank?

      # newest spelling first, so the first row seen per normalized_name wins.
      rows = MeetingParticipant.joins(:meeting)
                               .where(meetings: { project_id: project_ids }, user_id: nil)
                               .order(created_at: :desc)
                               .pluck(:normalized_name, :display_name)
      latest = {}
      rows.each { |normalized, display| latest[normalized] ||= display }
      latest.values.map { |display| { display_name: display } }
    end

    def set_meeting
      # Scoped to @project.meetings: a foreign-project (or foreign-tenant) id is
      # simply not found → 404, which rejects cross-project/tenant access.
      @meeting = @project.meetings.find(params[:id])
    end

    # The list this request shows (MeetingList): the project's own, or "Alle
    # Meetings" after a save from that page's modal.
    def meeting_list_project
      overview_modal? ? nil : @project
    end

    def ad_hoc_filter_params
      @ad_hoc_filter_params ||= begin
        filters = nested_param(:filter)
        filters['participant'] ||= [params[:participant].to_s] if params[:participant].present?
        filters
      end
    end

    # Full row for the detail pane (it renders notes/transcript) — deliberately a
    # fresh lookup, NOT derived from the LIST_COLUMNS-narrowed list relation.
    def find_selected_meeting(meeting_id)
      policy_scope(@project.meetings).find_by(id: meeting_id)
    end

    # A new meeting can be saved from two pages, and they share no frame. The
    # project page refreshes its list and opens the detail; the org-wide list has
    # neither of those frames, so it refreshes its own table instead and lets
    # meeting_modal_controller close the modal on the successful submit.
    def created_streams(meeting)
      return overview_created_streams(meeting) if overview_modal?

      [created_address_stream(meeting)] + saved_streams(meeting, 'flash.meetings.created')
    end

    def created_address_stream(meeting)
      url = organisation_project_meetings_path(
        @current_organisation,
        @project,
        meeting_index_query.merge(meeting_id: meeting.id)
      )
      view_context.turbo_stream_action_tag(:replaceAddress, target: DETAIL_FRAME_ID, url: url)
    end

    helper_method :meeting_index_query

    def meeting_index_query
      Meetings::ListState.extract(params)
    end

    # The refreshed list keeps the state the page is showing (the form carries it
    # as hidden fields), so a meeting saved for another project (or without the
    # searched word) is legitimately not in it. Then the list looks as if the save
    # failed, so the flash says which of the two happened. The list is the one
    # MeetingsOverviewController renders (MeetingList, project nil).
    def overview_created_streams(meeting)
      results = filtered_meetings
      hidden = !@meeting_list_query.exists?(id: meeting.id)

      [
        turbo_stream.replace(OVERVIEW_LIST_FRAME_ID,
                             partial: 'organisations/meetings_overview/results',
                             locals: { meetings: results }),
        flash_stream(hidden ? 'flash.meetings.created_hidden_by_filter' : 'flash.meetings.created')
      ]
    end

    # Success response for create/update: refresh the list frame (new/edited row,
    # re-sorted) with the meeting selected, show the detail, and flash.
    def saved_streams(meeting, flash_key)
      [
        list_stream(selected: meeting),
        turbo_stream.update(detail_frame_id, partial: 'organisations/meetings/meeting_show',
                                             locals: { meeting: meeting, detail_frame_id: detail_frame_id }),
        flash_stream(flash_key)
      ]
    end

    def list_stream(selected:)
      meetings = filtered_meetings
      turbo_stream.replace(LIST_FRAME_ID, partial: 'organisations/meetings/meetings_results',
                                          locals: { meetings: meetings, selected_meeting: selected })
    end

    def flash_stream(flash_key, type: :notice)
      turbo_stream.prepend('flash', partial: 'layouts/flash', locals: { flash: { type => t(flash_key) } })
    end

    # Friendly, no-write response for guarded cases (blank content / AI not
    # usable / failed toggle) — shared by create_summary and toggle_search.
    # :unprocessable_content so Turbo does not treat it as a navigation.
    def respond_hint(flash_key)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: flash_stream(flash_key, type: :alert), status: :unprocessable_content }
        format.html do
          redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_index_query.merge(meeting_id: @meeting.id)),
                      alert: t(flash_key)
        end
      end
    end

    # Immediate feedback for the clicking user: replace the summary section with
    # its "wird erstellt…" state. The after_update_commit broadcast delivers the
    # same to any other viewer and the final state when the job finishes.
    # Reloaded first (review #235): a fast-failing job (missing credential, quota)
    # can finish BEFORE this response reaches the client — rendering the fresh row
    # keeps the response from overwriting the final broadcast with a stale spinner.
    def summary_section_stream(meeting)
      meeting.reload
      [
        turbo_stream.replace("#{helpers.dom_id(meeting)}_summary_section",
                             partial: 'organisations/meetings/summary_section',
                             locals: { meeting: meeting, can_write: true }),
        flash_stream('flash.meetings.summary_started')
      ]
    end

    # Immediate feedback for the toggling user: replace the status badge section
    # AND refresh the list frame — its status column must reflect the flip.
    # filtered_meetings reads the forwarded search/participant params (the
    # toggle form sends them as hidden fields), so active filters survive the
    # refresh. Reloaded first, mirroring summary_section_stream: the actor has
    # committed, and a fast-failing embedding job could even have finished.
    def search_status_stream(meeting, flash_key)
      meeting.reload
      [
        turbo_stream.replace("#{helpers.dom_id(meeting)}_search_status",
                             partial: 'organisations/meetings/search_status',
                             locals: { meeting: meeting, can_write: true }),
        list_stream(selected: meeting),
        flash_stream(flash_key)
      ]
    end

    # Re-render the inline form (new or edit) with validation errors into the
    # detail frame; :unprocessable_content so Turbo replaces from a failed submit.
    def render_form_with_errors(partial)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update(detail_frame_id, partial: partial,
                                                                    locals: { meeting: @meeting, detail_frame_id: detail_frame_id }),
                 status: :unprocessable_content
        end
        format.html do
          @meetings = filtered_meetings
          @new_meeting = @meeting
          render :index, status: :unprocessable_content
        end
      end
    end

    def render_detail_frame(partial, meeting)
      render html: helpers.turbo_frame_tag(detail_frame_id) {
        helpers.render(partial: partial, locals: { meeting: meeting, detail_frame_id: detail_frame_id })
      }.html_safe, layout: false
    end

    def detail_frame_id
      params[:frame_id].presence || DETAIL_FRAME_ID
    end

    # The org-wide modal's frame. Same form partial as the detail pane — only the
    # wrapper id, the cancel behaviour and the save context differ, so there is no
    # second copy of the meeting form to keep in step.
    def render_modal_frame(meeting, status: :ok)
      render html: helpers.turbo_frame_tag(MODAL_FRAME_ID) {
        helpers.render(partial: 'organisations/meetings/meeting_new_for_frame',
                       locals: modal_form_locals(meeting))
      }.html_safe, layout: false, status: status
    end

    # Validation errors from the modal go back INTO the modal: it stays open, the
    # project select above the frame keeps its value, and the messages sit with the
    # fields that caused them.
    def render_modal_frame_with_errors(meeting)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update(MODAL_FRAME_ID,
                                                   partial: 'organisations/meetings/meeting_new_for_frame',
                                                   locals: modal_form_locals(meeting)),
                 status: :unprocessable_content
        end
        format.html { render_modal_frame(meeting, status: :unprocessable_content) }
      end
    end

    def modal_form_locals(meeting)
      {
        meeting: meeting,
        detail_frame_id: MODAL_FRAME_ID,
        context: OVERVIEW_MODAL_CONTEXT,
        cancel_action: MODAL_CANCEL_ACTION
      }
    end

    def overview_modal?
      params[:context] == OVERVIEW_MODAL_CONTEXT
    end

    def meeting_params
      # participants: the chips field posts meeting[participants][i][display_name]
      # and [user_id]; the actor strips this key out before touching Meeting
      # columns and reconciles meeting_participants (Slice 1b).
      params.require(:meeting).permit(:title, :occurred_at, :duration_minutes, :notes, :transcript,
                                      :create_embeddings,
                                      participants: %i[display_name user_id])
    end
  end
end
