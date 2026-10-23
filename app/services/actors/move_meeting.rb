# frozen_string_literal: true

# Tier-1 actor: moves ONE meeting into another project of the same organisation
# (doc/meeting_verschieben_plan.md). The booked time and the meeting's
# notifications follow it, open AI ticket suggestions are dismissed (accepting
# one after the move would be refused anyway, AcceptTicketSuggestion compares the
# run's project), and both projects record the move.
#
# Refused, with a code: a meeting with linked tickets (the links point into the
# source project and the link controller keeps them same-project; a tombstone
# counts too), an active suggestion run (it carries the source project), the
# project the meeting is in, and a target the user may not write meetings in.
# The permission to move at all (move_meetings) is MeetingPolicy#move?, asked by
# the controller; the target check is repeated here because the actor writes it.
module Actors
  class MoveMeeting < BaseActor
    def initialize(meeting:, target_project:, current_user:)
      super()
      @meeting = meeting
      @source_project = meeting.project
      @target_project = target_project
      @current_user = current_user
    end

    def record
      @meeting
    end

    # What the move would take along or refuse on, without moving (the dialog).
    def preflight
      sessions = @meeting.time_sessions.where(deleted_at: nil)
      {
        time_sessions_count: sessions.count,
        billed_time_sessions_count: sessions.where(billed: true).count,
        open_suggestions_count: @meeting.meeting_ticket_suggestions.open.count,
        ticket_links_count: ticket_links.count
      }
    end

    def perform
      guard_target!
      # Row lock first, as AcceptTicketSuggestion does: a link or a run created
      # concurrently waits for the move instead of slipping past the guards.
      @meeting.lock!
      guard_movable!

      @meeting.update_columns(project_id: @target_project.id, updated_at: Time.current)
      @meeting.time_sessions.update_all(project_id: @target_project.id)
      # The inbox rule reads a notification's project (see Tickets::Mover): left
      # behind, a row stays readable for whoever reads meetings in the source.
      Notification.where(notifiable: @meeting).update_all(project_id: @target_project.id)
      @meeting.meeting_ticket_suggestions.open
              .update_all(status: MeetingTicketSuggestion.statuses[:dismissed], updated_at: Time.current)

      @source_project.track_meeting_moved_out(@meeting, @target_project)
      @target_project.track_meeting_moved_in(@meeting, @source_project)
      @meeting.reload
    end

    private

    # The archive check is explicit: the area check lets account admins write
    # into an archived project (the admin short-circuit in ProjectAccessService
    # comes before its archive rule), and nobody moves a meeting into one.
    def guard_target!
      refuse!(:same_project) if @target_project.id == @source_project.id
      return if @target_project.organisation_id == @meeting.organisation_id &&
                !@target_project.archived? &&
                ProjectPolicy.new(@current_user, @target_project).area_access?(:meetings, :write)

      refuse!(:forbidden_target)
    end

    def guard_movable!
      refuse!(:has_ticket_links) if ticket_links.exists?
      refuse!(:suggestion_run_active) if suggestion_run_active?
    end

    def ticket_links
      @meeting.outgoing_references.where(target_type: 'Ticket')
    end

    # A run that lost its job releases the move after the same staleness window
    # that releases the button (Meeting::SUGGESTIONS_STALE_AFTER).
    def suggestion_run_active?
      @meeting.suggestions_generation_running? ||
        MeetingTicketSuggestionRun.where(meeting_id: @meeting.id).any? { |run| run.active? && !run.stale? }
    end

    def refuse!(code)
      raise ActorError.new(I18n.t("services.actors.move_meeting.#{code}"), code: code)
    end
  end
end
