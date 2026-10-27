# frozen_string_literal: true

# Linking a meeting participant to the people directory (S2b): new renders the
# dialog "Mit Person verknüpfen" into its frame (?q= reloads only its list),
# create links (a person, a member, or a person created in the same step),
# destroy unlinks. Every answer redraws the participant row of THIS meeting.
#
# Rights, before anything is read or written:
#   1. write on meetings in the project of the route: the area gate of
#      ProjectController;
#   2. MeetingPolicy#link_participants?: the meeting write again, plus
#      view_people (the dialog lists the directory). The participant row asks
#      the same policy to show its link action;
#   3. creating a person needs manage_people, which the actor asks.
# The actor resolves every id (Actors::LinkMeetingParticipant) and takes the
# meeting's row lock: a meeting moved out of this project meanwhile is gone.
module Organisations
  class MeetingParticipantLinksController < Organisations::BaseController
    include ProjectController

    # The token of one dialog instance, echoed by its form. Anything else is no token.
    MODAL_TOKEN = /\A\h{16}\z/
    # How many people the dialog lists besides the suggestions.
    LIST_LIMIT = 20
    INTERNAL_CODES = %i[internal_error].freeze
    NOT_FOUND_CODES = %i[not_found].freeze

    # The token first: an answer for a meeting that is gone still closes the
    # dialog instance that asked.
    before_action :read_modal_token, only: %i[create destroy]
    before_action :set_meeting_and_participant
    before_action :authorize_link

    def new
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
      @choice = scalar_param(:choice)
      @new_person_name = scalar_param(:new_person_name)
      result = ::Actors::LinkMeetingParticipant.call(**actor_arguments, **choice_arguments)
      return changed(t('flash.meeting_participant_links.linked')) if result.success?

      refused(result)
    end

    def destroy
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

    def read_modal_token
      @modal_token = scalar_param(:modal_token).to_s[MODAL_TOKEN]
    end

    # Scoped to the route's project: a meeting of another project or another
    # organisation, or a participant of another meeting, is not found. That is
    # also what a dialog or a panel left open meets when the meeting was moved
    # or the participant removed meanwhile, so it gets an answer the dialog can
    # show, not an error page inside the frame.
    def set_meeting_and_participant
      @meeting_id = params[:meeting_id].to_s
      @meeting = @project.meetings.find_by(id: @meeting_id)
      @participant = @meeting&.meeting_participants&.find_by(id: params[:participant_id])
      gone([t('services.actors.link_meeting_participant.not_found')]) if @participant.nil?
    end

    def authorize_link
      authorize @meeting, :link_participants?
    end

    def actor_arguments
      { meeting: @meeting, project: @project, participant_id: @participant.id, current_user: current_user }
    end

    # What the actor gets from the pick. Anything that is no pick is nothing,
    # and the actor answers "nothing picked".
    def choice_arguments
      choice = ::Meetings::ParticipantLinkChoice.parse(@choice)
      case choice&.kind
      when :new_person then { new_person: { name: @new_person_name.to_s } }
      when :person then { person_id: choice.id }
      when :member then { member_id: choice.id }
      else {}
      end
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
      return gone(result.errors) if NOT_FOUND_CODES.include?(result.code)

      @errors = result.errors
      status = INTERNAL_CODES.include?(result.code) ? :internal_server_error : :unprocessable_content
      respond_to do |format|
        format.turbo_stream { render 'organisations/meeting_participant_links/refused', status: status }
        format.html { redirect_to meeting_path, alert: @errors.to_sentence, status: :see_other }
      end
    end

    # Nothing of the meeting is drawn again: it may be in another project now.
    # A stream closes the dialog with a flash; the frame of the dialog (new)
    # shows the reason in place; a plain form submit goes back to the meetings.
    def gone(errors)
      @errors = errors
      respond_to do |format|
        format.turbo_stream { render 'organisations/meeting_participant_links/gone', status: :not_found }
        format.html do
          if action_name == 'new'
            render 'organisations/meeting_participant_links/not_found', layout: false, status: :not_found
          else
            redirect_to organisation_project_meetings_path(current_organisation, @project),
                        alert: @errors.to_sentence, status: :see_other
          end
        end
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
