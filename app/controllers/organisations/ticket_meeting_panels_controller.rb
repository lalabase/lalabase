# frozen_string_literal: true

# The meeting beside the ticket (doc/ticket_meeting_panel_plan.md, S1): a read-only panel in
# the third lane of the ticket page's grid. It only reads, so there is no actor.
#
#   * The ticket comes through TicketPolicy::Scope, within the project of the address.
#   * The meetings are Tickets::LinkedMeetings: those that link to the ticket AND that this
#     person may read, each judged against its OWN project (a moved ticket keeps links into
#     its old project). ?meeting_id= picks one of them; without it the newest opens.
#   * A project, ticket or meeting that is missing, not readable or of another organisation
#     is the same 404 with the same body. Inside the frame it says "not available", so the
#     panel does not show Turbo's "Content missing"; it tells nothing about which part failed.
#   * Only a frame request of ticket_meeting_panel gets the panel. Any other request (a
#     bookmark, a new tab, a modified click) goes to the meeting's own page.
module Organisations
  class TicketMeetingPanelsController < Organisations::BaseController
    FRAME_ID = 'ticket_meeting_panel'

    def show
      @project = Project.find_by(id: params[:project_id])
      @ticket = @project && policy_scope(Ticket).where(project: @project).find_by(id: params[:ticket_id])
      @meetings = @ticket ? newest_first(::Tickets::LinkedMeetings.call(ticket: @ticket, user: current_user)) : []
      @meeting = selected_meeting
      return unavailable if @meeting.nil?

      authorize @meeting, :show?
      return redirect_to(meeting_page) unless panel_request?

      @linked_tickets = linked_tickets
      render layout: false
    end

    private

    def newest_first(meetings)
      meetings.to_a.sort_by(&:occurred_at).reverse
    end

    def selected_meeting
      requested = params[:meeting_id]
      return @meetings.first if requested.blank?

      # Postgres accepts a UUID in either case and answers in lower case.
      @meetings.find { |meeting| meeting.id == requested.to_s.downcase }
    end

    def panel_request?
      request.headers['Turbo-Frame'] == FRAME_ID
    end

    def meeting_page
      organisation_project_meetings_path(current_organisation, @meeting.project, meeting_id: @meeting.id)
    end

    # The tickets of the open meeting this person may read, oldest link first, each with
    # its own project (one may have moved). The ticket beside the panel is among them.
    def linked_tickets
      ids = @meeting.outgoing_references.where(target_type: Ticket.polymorphic_name)
                    .order(:created_at).pluck(:target_id)
      readable = policy_scope(Ticket).where(id: ids).includes(:project).index_by(&:id)
      ids.filter_map { |id| readable[id] }
    end

    def unavailable
      skip_authorization
      raise ActiveRecord::RecordNotFound unless panel_request?

      render :unavailable, layout: false, status: :not_found
    end
  end
end
