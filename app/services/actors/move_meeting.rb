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
        ticket_links_count: ticket_links.count,
        bound_analyses_count: bound_analyses.size
      }
    end

    def perform
      guard_target!
      # Row lock first. Everything that ties the meeting to its project takes the
      # same lock and looks again (AcceptTicketSuggestion, a manual ticket link,
      # SaveTimeSession), so none of them lands in the old project after a move.
      @meeting.lock!
      guard_movable!

      @meeting.update_columns(project_id: @target_project.id, updated_at: Time.current)
      @meeting.time_sessions.update_all(project_id: @target_project.id)
      # The inbox rule reads a notification's project (see Tickets::Mover): left
      # behind, a row stays readable for whoever reads meetings in the source.
      Notification.where(notifiable: @meeting).update_all(project_id: @target_project.id)
      @meeting.meeting_ticket_suggestions.open
              .update_all(status: MeetingTicketSuggestion.statuses[:dismissed], updated_at: Time.current)
      carry_meeting_citations

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

    # lock! reloads the row: a move that committed while this one waited has
    # taken the meeting out of the project this move was checked against.
    def guard_movable!
      refuse!(:moved_meanwhile) if @meeting.project_id != @source_project.id
      refuse!(:has_ticket_links) if ticket_links.exists?
      refuse!(:published_analyses_bound) if bound_analyses.any?
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

    # A saved analysis may be published when its sources are this meeting
    # (Assistant::AnalysisSources.publishable?), and a citation of the meeting
    # names the project it was read in; the source list links through that
    # project too (Lalabase::CitationLink). The meeting and its analyses are the
    # same records after the move, so their citations follow them, in the
    # provenance and in the displayed list. Every other source keeps its
    # project and stays a reason not to publish (a chat narrowed to the source
    # project too, see #bound_analyses).
    CARRIED_LISTS = %w[provenance citations].freeze

    def carry_meeting_citations
      analysis_ids = @meeting.meeting_analyses.pluck(:id)
      @meeting.meeting_analyses.where.not(source_context: nil).find_each do |analysis|
        context = analysis.source_context
        carried = CARRIED_LISTS.select { |key| context[key].is_a?(Array) }.index_with do |key|
          context[key].map { |citation| carry(citation, analysis_ids, to: @target_project.id) }
        end
        next if carried.all? { |key, list| list == context[key] }

        analysis.update_columns(source_context: context.merge(carried))
      end
    end

    def carry(citation, analysis_ids, to:)
      return citation unless citation.is_a?(Hash)

      own = (citation['type'] == 'meeting' && citation['id'] == @meeting.id) ||
            (citation['type'] == 'meeting_analysis' && analysis_ids.include?(citation['id']))
      own ? citation.merge('project_id' => to) : citation
    end

    # Published analyses that could not be published in the target, the
    # meeting citations already carried along: their other sources (in practice
    # a chat narrowed to the source project) stay behind. The move does not
    # decide their visibility silently; they are unpublished first. Asked
    # through the publication rule itself, with the meeting in a project that
    # is not the source: the answer is the same for every target, so the dialog
    # can ask before one is chosen.
    ELSEWHERE = 'elsewhere'

    def bound_analyses
      @bound_analyses ||= begin
        moved = Struct.new(:id, :project_id).new(@meeting.id, ELSEWHERE)
        analysis_ids = @meeting.meeting_analyses.pluck(:id)
        @meeting.meeting_analyses.where(is_private: false).where.not(source_context: nil).reject do |analysis|
          context = analysis.source_context
          provenance = context['provenance']
          carried = provenance.is_a?(Array) ? provenance.map { |c| carry(c, analysis_ids, to: ELSEWHERE) } : provenance
          Assistant::AnalysisSources.publishable?(context: context.merge('provenance' => carried), meeting: moved)
        end
      end
    end

    def refuse!(code)
      raise ActorError.new(I18n.t("services.actors.move_meeting.#{code}"), code: code)
    end
  end
end
