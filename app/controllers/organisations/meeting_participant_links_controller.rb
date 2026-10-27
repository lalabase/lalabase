# frozen_string_literal: true

# Linking a meeting participant to the people directory (S2b): new renders the
# dialog "Mit Person verknüpfen" into its frame (?q= reloads only its list),
# create links (a person, a member, or a person created in the same step),
# destroy unlinks. Every answer redraws the participant row of THIS meeting.
#
# Rights, before anything is read or written:
#   1. write on meetings in the project of the route: the area gate of
#      ProjectController and authorize @meeting, :update?;
#   2. view_people: authorize Person, :index? (the directory itself);
#   3. creating a person needs manage_people, which the actor asks again.
# The actor resolves every id (Actors::LinkMeetingParticipant) and takes the
# meeting's row lock: a meeting moved out of this project meanwhile is a 404.
module Organisations
  class MeetingParticipantLinksController < Organisations::BaseController
    include ProjectController

    # The token of one dialog instance, echoed by its form. Anything else is no token.
    MODAL_TOKEN = /\A\h{16}\z/
    # How many people the dialog lists besides the suggestions.
    LIST_LIMIT = 20
    # A choice of the dialog: a person row, a member, or a new person.
    CHOICE = /\A(?<kind>person|member):(?<id>\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
    NEW_PERSON = 'new'
    INTERNAL_CODES = %i[internal_error].freeze
    NOT_FOUND_CODES = %i[not_found].freeze

    before_action :set_meeting_and_participant

    def new
      authorize @meeting, :update?
      authorize Person, :index?

      @query = scalar_param(:q).to_s
      if request.headers['Turbo-Frame'] == helpers.participant_link_results_id(@participant)
        render partial: 'organisations/meeting_participant_links/results',
               locals: { meeting: @meeting, participant: @participant, query: @query, choice: nil }
        return
      end

      @modal_token = SecureRandom.hex(8)
      render layout: false
    end

    def create
      authorize @meeting, :update?
      authorize Person, :index?

      @modal_token = scalar_param(:modal_token).to_s[MODAL_TOKEN]
      @choice = scalar_param(:choice)
      @new_person_name = scalar_param(:new_person_name)
      result = ::Actors::LinkMeetingParticipant.call(**actor_arguments, **choice_arguments)
      return changed(t('flash.meeting_participant_links.linked')) if result.success?

      refused(result)
    end

    def destroy
      authorize @meeting, :update?
      authorize Person, :index?

      @modal_token = scalar_param(:modal_token).to_s[MODAL_TOKEN]
      result = ::Actors::LinkMeetingParticipant.call(**actor_arguments, unlink: true)
      return changed(t('flash.meeting_participant_links.unlinked')) if result.success?

      refused(result)
    end

    private

    # ProjectController derives the area from the controller name
    # ("meeting_participant_links"), which is no area. Linking is a meeting write.
    def determine_access_area
      :meetings
    end

    # Scoped to the route's project: a meeting of another project or another
    # organisation, or a participant of another meeting, is not found.
    def set_meeting_and_participant
      @meeting = @project.meetings.find(params[:meeting_id])
      @participant = @meeting.meeting_participants.find(params[:participant_id])
    end

    def actor_arguments
      { meeting: @meeting, project: @project, participant_id: @participant.id, current_user: current_user }
    end

    def choice_arguments
      return { new_person: { name: @new_person_name.to_s } } if @choice == NEW_PERSON

      match = CHOICE.match(@choice.to_s)
      return {} unless match

      match[:kind] == 'person' ? { person_id: match[:id] } : { member_id: match[:id] }
    end

    # The row of this meeting's participants, the dialog closed, the flash.
    def changed(message)
      respond_to do |format|
        format.turbo_stream do
          @flash_message = { notice: message }
          render 'organisations/meeting_participant_links/changed'
        end
        format.html { redirect_to meeting_path, notice: message, status: :see_other }
      end
    end

    # The dialog again with the reason, in place of the instance that sent it;
    # our own failure is a 500. Not found (a person or member out of reach, or the
    # meeting moved meanwhile, which the lock reloaded into its new project) closes
    # the dialog with the reason and draws nothing of the meeting again.
    def refused(result)
      @errors = result.errors
      return gone if NOT_FOUND_CODES.include?(result.code)

      status = INTERNAL_CODES.include?(result.code) ? :internal_server_error : :unprocessable_content
      respond_to do |format|
        format.turbo_stream { render 'organisations/meeting_participant_links/refused', status: status }
        format.html { redirect_to meeting_path, alert: @errors.to_sentence, status: :see_other }
      end
    end

    def gone
      respond_to do |format|
        format.turbo_stream { render 'organisations/meeting_participant_links/gone', status: :not_found }
        format.html { redirect_to meeting_path, alert: @errors.to_sentence, status: :see_other }
      end
    end

    def meeting_path
      organisation_project_meetings_path(current_organisation, @project, meeting_id: @meeting.id)
    end

    # A nested or repeated parameter is no value here.
    def scalar_param(key)
      value = params[key]
      value.is_a?(String) ? value : nil
    end
  end
end
