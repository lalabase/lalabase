# frozen_string_literal: true

# A meeting a program sends, for both surfaces (POST /api/v1/organisations/:id/meetings
# and the MCP tool create_meeting): where it lands and who took part. The write is
# Actors::SaveMeeting, the web form's, so the activity and the participants run as
# they do there. Each surface authorizes `meeting_for_policy` itself, which is what
# marks its tripwire, and answers a refusal in its own envelope.
#
# Without a project the meeting lands in the organisation's inbox
# (Organisation#meeting_inbox). The difference to a named project is the refusal:
# the caller did not choose the inbox, so an inbox out of reach says so (forbidden)
# instead of a 404 nobody could act on. It tells nothing but that the organisation
# has one.
#
# A participant is a name, optionally with `ref`, the id the people list hands out
# (member:<uuid>, person:<uuid>). A ref is resolved through People::Lookup, so the
# token's reach and the writer's people right apply, and a ref that does not resolve
# refuses the whole meeting: sent on without its link, the meeting would look fine
# and the person's history would lack it.
#
# Entry point: new, refusal, meeting_for_policy, save, .summary
module Meetings
  class Intake
    # reason: names the refusal for a program. code: the error class of both surfaces.
    Refusal = Data.define(:reason, :code)

    FIELDS = %i[title occurred_at duration_minutes notes transcript].freeze

    NOT_FOUND = Refusal.new(reason: :not_found, code: :not_found)
    INBOX_MISSING = Refusal.new(reason: :meeting_inbox_missing, code: :refused)
    INBOX_FORBIDDEN = Refusal.new(reason: :meeting_inbox_forbidden, code: :forbidden)
    PROJECT_ARCHIVED = Refusal.new(reason: :project_archived, code: :refused)
    UNKNOWN_PARTICIPANT = Refusal.new(reason: :unknown_participant, code: :invalid_input)

    attr_reader :project, :refusal, :meeting

    # #refusal is a Refusal, or nil when the meeting may go on to the policy and #save.
    # @param organisation [Organisation] reached by the token; the caller holds its tenant
    # @param reach [PersonalAccessToken::Reach]
    # @param input [Hash] project_id, FIELDS, participants: [{ display_name:, ref: }]
    def initialize(organisation:, reach:, viewer:, input:)
      @organisation = organisation
      @reach = reach
      @viewer = viewer
      @input = input.to_h.deep_symbolize_keys
      @participants = []
      @links = {}
      @refusal = resolve_target || resolve_participants
    end

    # What the surface authorizes :create? on.
    def meeting_for_policy
      project.meetings.build
    end

    # @return [BaseActor::Result]
    def save
      actor = Actors::SaveMeeting.new(project: project, params: meeting_params, current_user: @viewer,
                                      participant_links: @links)
      actor.call.tap { @meeting = actor.record }
    end

    # The answer of both surfaces, and it stays this small: an idempotent write
    # stores its answer for good (Mcp::IdempotencyStore), outside the meeting, so
    # a transcript in here would survive the meeting's deletion.
    def self.summary(meeting)
      {
        id: meeting.id,
        project_id: meeting.project_id,
        in_meeting_inbox: meeting.project.meeting_inbox?,
        title: meeting.title,
        occurred_at: meeting.occurred_at.iso8601,
        path: Rails.application.routes.url_helpers.organisation_project_meeting_path(
          meeting.organisation_id, meeting.project_id, meeting
        )
      }
    end

    private

    def meeting_params
      fields = @input.slice(*FIELDS)
      fields[:participants] = @participants if @input.key?(:participants)
      fields.with_indifferent_access
    end

    def resolve_target
      return resolve_inbox if @input[:project_id].blank?

      @project = @organisation.projects.find_by(id: @input[:project_id])
      return NOT_FOUND unless @reach.project?(@project)

      # Asked here, not left to the policy: its area check lets an account admin
      # write into an archived project (see MeetingPolicy#move?).
      PROJECT_ARCHIVED if @project.archived?
    end

    def resolve_inbox
      @project = @organisation.meeting_inbox
      return INBOX_MISSING if @project.nil?
      return if @reach.project?(@project) && Pundit.policy!(@viewer, meeting_for_policy).create?

      INBOX_FORBIDDEN
    end

    def resolve_participants
      entries = @input.fetch(:participants, [])
      return UNKNOWN_PARTICIPANT unless entries.is_a?(Array) && entries.all?(Hash)

      entries.each do |entry|
        participant = { display_name: entry[:display_name], user_id: nil }
        if entry[:ref].present?
          found = directory_entry(entry[:ref])
          return UNKNOWN_PARTICIPANT if found.nil?

          attach(participant, found)
        end
        @participants << participant
      end
      nil
    end

    # A member is linked by user_id, the path the meeting form uses; a contact by
    # person_id, which the actor takes from participant_links, never from a payload.
    def attach(participant, found)
      if found.member?
        participant[:user_id] = found.user.id
      else
        @links[MeetingParticipant.normalize_name(participant[:display_name])] = found.person.id
      end
    end

    def directory_entry(ref)
      people = people_lookup
      return nil unless people&.allowed?

      people.entry(ref)
    rescue People::Lookup::InvalidArgument
      nil
    end

    def people_lookup
      return @people_lookup if defined?(@people_lookup)

      @people_lookup = People::Lookup.for_token(reach: @reach, viewer: @viewer, organisation_id: @organisation.id)
    end
  end
end
