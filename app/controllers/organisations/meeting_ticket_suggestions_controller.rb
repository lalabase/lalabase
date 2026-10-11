# frozen_string_literal: true

# AI ticket suggestions for a meeting (Gespräche Slice 8, E22). Nested under the
# meeting: `run` (collection) enqueues the async LLM run for the whole meeting;
# `accept`/`dismiss` (member) act on one suggestion. All three are :meetings writes;
# `accept` is additionally a CROSS-AREA write (it creates a real ticket) and so
# requires :tickets write on top — server-side here AND on the UI button (Slice-3
# cross-area lesson). Visibility is NOT per-creator (unlike analyses), so the
# actions authorize the MEETING (MeetingPolicy#update?), not a per-suggestion policy.
#
# `run` delegates source, AI availability and concurrent-start checks to the shared
# StartTicketSuggestionRun actor used by the assistant.
module Organisations
  class MeetingTicketSuggestionsController < Organisations::BaseController
    include ProjectController

    before_action :set_meeting
    before_action :set_suggestion, only: %i[accept dismiss]

    def run
      authorize @meeting, :update?
      # Creation lives in the assistant since #817: without its gate an old open page
      # gets a 403 that names that move, not the generic "not available" of a run.
      return respond_hint('flash.meeting_ticket_suggestions.assistant_unavailable', status: :forbidden) unless assistant_creation_allowed?

      result = Actors::StartTicketSuggestionRun.call(meeting: @meeting, current_user: current_user)
      return respond_hint(result.errors.first, translate: false) unless result.success?

      @meeting.reload
      return respond_section(result.resource.error, type: :alert, translate: false) if result.resource.reload.failed?

      respond_section('flash.meeting_ticket_suggestions.started')
    end

    def accept
      authorize @meeting, :update?

      # Cross-area gate: creating a ticket needs :tickets write (the UI hides the
      # button too). Rejected BEFORE any state change, with 403.
      return respond_no_ticket_write unless can_write_tickets?

      result = Actors::AcceptTicketSuggestion.call(meeting: @meeting, suggestion: @suggestion,
                                                   current_user: current_user)
      if result.success?
        respond_section('flash.meeting_ticket_suggestions.accepted', refresh_links: true)
      else
        # 3A already_processed OR a ticket-creation failure (status rolled back to
        # open) — re-render the section so it reflects the current state, with the
        # actor's readable message. No second ticket either way.
        respond_section(result.errors.first.to_s, type: :alert, translate: false)
      end
    end

    def dismiss
      authorize @meeting, :update?

      # Only an open suggestion can be dismissed; a concurrent accept/dismiss is a no-op.
      @suggestion.dismiss_if_open
      respond_section('flash.meeting_ticket_suggestions.dismissed')
    end

    private

    # ProjectController derives the area from the controller name
    # ("meeting_ticket_suggestions" → :meeting_ticket_suggestion, no real area →
    # denies everyone). These live in the :meetings area (Slice-3 lesson).
    def determine_access_area
      :meetings
    end

    def set_meeting
      # Scoped to @project.meetings: a foreign-project/tenant meeting id 404s.
      @meeting = @project.meetings.find(params[:meeting_id])
    end

    def set_suggestion
      # Meeting-scoped (Slice-3/1A lesson): a foreign suggestion id 404s — rejects
      # cross-project/tenant tampering before any write.
      @suggestion = @meeting.meeting_ticket_suggestions.find(params[:id])
    end

    def can_write_tickets?
      policy(@project).area_access?(:tickets, :write)
    end

    def assistant_creation_allowed?
      ChatPolicy.assistant_gate_open?(current_user, current_organisation)
    end

    # Replace the suggestions section frame (freshly rendered) + flash.
    def respond_section(flash_key, type: :notice, translate: true, refresh_links: false)
      message = translate ? t(flash_key) : flash_key.presence || t('flash.meeting_ticket_suggestions.error')
      respond_to do |format|
        format.turbo_stream { render turbo_stream: [section_replace(refresh_links: refresh_links), flash_stream(message, type: type)] }
        format.html { redirect_to_meeting(type => message) }
      end
    end

    # Friendly, no-re-render response for the guarded cases (running / blank / AI
    # unavailable / no ticket-write). Default :unprocessable_entity so Turbo does not
    # treat it as navigation; :forbidden for the cross-area denial and the assistant gate.
    # Cross-area denial (accept without :tickets write) → 403 hint, no re-render.
    def respond_no_ticket_write
      respond_hint('flash.meeting_ticket_suggestions.no_ticket_write', status: :forbidden)
    end

    def respond_hint(flash_key, status: :unprocessable_entity, translate: true)
      message = translate ? t(flash_key) : flash_key
      respond_to do |format|
        format.turbo_stream { render turbo_stream: flash_stream(message, type: :alert), status: status }
        format.html { redirect_to_meeting(alert: message) }
      end
    end

    def section_replace(refresh_links: false)
      turbo_stream.replace(
        helpers.meeting_ticket_suggestions_frame_id(@meeting),
        partial: 'organisations/meetings/ticket_suggestions_section',
        locals: { meeting: @meeting, announce: true, announce_links: refresh_links }
      )
    end

    def flash_stream(message, type: :notice)
      turbo_stream.prepend('flash', partial: 'layouts/flash', locals: { flash: { type => message } })
    end

    def redirect_to_meeting(**flash_opts)
      redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_id: @meeting.id),
                  **flash_opts
    end
  end
end
