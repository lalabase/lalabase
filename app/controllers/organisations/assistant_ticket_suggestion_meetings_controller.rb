# frozen_string_literal: true

module Organisations
  # Only readable, writable adopted references become target options.
  class AssistantTicketSuggestionMeetingsController < Organisations::BaseController
    def index
      authorize Chat.new(organisation: current_organisation, user: current_user), :create?
      ids = Array(params[:meeting_ids]).first(Assistant::ReferenceRegistry::MAX_REFERENCES)
      meetings = policy_scope(Meeting).where(organisation: current_organisation, id: ids).includes(:project).select do |meeting|
        !meeting.project.archived? && MeetingPolicy.new(current_user, meeting).update?
      end
      render json: meetings.map { |meeting| { id: meeting.id, title: meeting.one_line_title(max: 120), project: meeting.project.name } }
    end
  end
end
