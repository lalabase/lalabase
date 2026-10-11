# frozen_string_literal: true

# Manual bidirectional Meeting↔Ticket links (Gespräche Slice 3). A link is a
# trivial write (one Reference create!/destroy, no side effects), so per the
# CLAUDE.md seam rule it lives in a controller — NOT in Actors::SaveMeeting.
#
# The Reference row is source: Meeting → target: Ticket (reusing the polymorphic
# wiki link index). The meeting owns the link (dependent: :destroy on
# Meeting#outgoing_references); a deleted target ticket leaves a tombstone.
#
# Authorization: writing a link needs :meetings WRITE on the project (the link
# belongs to the meeting). The target ticket MUST belong to the SAME project —
# looked up strictly through @project.tickets so a tampered/foreign id is 404,
# not a cross-project/tenant link.
module Organisations
  class MeetingTicketLinksController < Organisations::BaseController
    include ProjectController

    before_action :set_meeting

    def create
      # :meetings write (MeetingPolicy#update? — the link belongs to the meeting).
      authorize @meeting, :update?

      # Picker submitted with no selection: friendly no-op, not a 500 (find("") would
      # raise on the UUID column). This is the realistic empty-submit path.
      return respond_link_result(:alert, 'flash.meeting_ticket_links.blank_selection') if params[:ticket_id].blank?

      # Tampering guard: a foreign-project/tenant ticket id is not found here and
      # bubbles to a 404 (same pattern as ensure_valid_subject in TimeSessions).
      ticket = @project.tickets.find(params[:ticket_id])

      # Friendly duplicate handling (unique index on source+target). The pre-check
      # covers the normal "clicked twice" case; the rescue is the race backstop.
      return respond_link_result(:alert, 'flash.meeting_ticket_links.already_linked') if @meeting.outgoing_references.exists?(target: ticket)

      @meeting.outgoing_references.create!(
        organisation: @current_organisation,
        target: ticket,
        # Snapshot the live title for the tombstone shown after a target delete.
        # Truncate: the snapshot column is capped at 255 and must never fail the save.
        target_title_snapshot: ticket.display_title&.truncate(255)
      )
      respond_link_result(:notice, 'flash.meeting_ticket_links.created')
    rescue ActiveRecord::RecordNotUnique
      respond_link_result(:alert, 'flash.meeting_ticket_links.already_linked')
    end

    def destroy
      authorize @meeting, :update?

      # Scoped to this meeting's outgoing references: a foreign reference id is 404.
      @meeting.outgoing_references.find(params[:id]).destroy
      respond_link_result(:notice, 'flash.meeting_ticket_links.removed')
    end

    private

    # ProjectController#authorize_project_access! derives the area from the
    # controller name ("meeting_ticket_links" → :meeting_ticket_link, which is no
    # real area and would deny everyone). This IS a meetings-area action: writing a
    # link needs :meetings write, exactly what the auto-gate then checks for
    # create/destroy (both write actions).
    def determine_access_area
      :meetings
    end

    def set_meeting
      # Scoped to @project.meetings: a foreign-project/tenant meeting id is 404,
      # which rejects cross-project/tenant access before any link is touched.
      @meeting = @project.meetings.find(params[:meeting_id])
    end

    # Refresh just the "Verknüpfte Tickets" turbo-frame (re-rendered with the new
    # link list and a reset picker) + flash; HTML fallback redirects to the meeting.
    # flash_type is :notice or :alert — the two keys both redirect_to and the flash
    # partial understand; it is used symmetrically for the turbo and HTML branches.
    def respond_link_result(flash_type, flash_key)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            # Replace exactly the section's own turbo-frame. The frame id is defined
            # ONCE in MeetingsHelper and reused by the section partial, so this
            # replace target can never drift from what the view renders.
            turbo_stream.replace(helpers.meeting_ticket_links_frame_id(@meeting),
                                 partial: 'organisations/meetings/ticket_links_section',
                                 locals: { meeting: @meeting }),
            turbo_stream.prepend('flash', partial: 'layouts/flash',
                                          locals: { flash: { flash_type => t(flash_key) } })
          ]
        end
        format.html do
          redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_id: @meeting.id),
                      flash_type => t(flash_key)
        end
      end
    end
  end
end
