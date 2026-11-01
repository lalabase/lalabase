# frozen_string_literal: true

module Api
  module V1
    # POST /api/v1/organisations/:organisation_id/meetings
    #
    # Under the organisation, not the project: the project may be missing, the
    # meeting then lands in the inbox. The rule is Meetings::Intake, shared with
    # the MCP tool create_meeting; the write is Actors::SaveMeeting.
    class MeetingsController < BaseController
      idempotent :create

      def create
        organisation = Organisation.find(params[:organisation_id])

        with_organisation_scope(organisation) do
          intake = Meetings::Intake.new(organisation: organisation, reach: current_token.reach, viewer: current_user,
                                        input: meeting_input)
          next render_refusal(intake.refusal) if intake.refusal

          with_project_scope(intake.project) do
            authorize intake.project, :show?
            authorize intake.meeting_for_policy, :create?
            answer(intake)
          end
        end
      end

      private

      def answer(intake)
        result = intake.save
        return render json: { data: Meetings::Intake.summary(intake.meeting) }, status: :created if result.success?
        return render_error(error: 'internal_error', status: :internal_server_error) if result.code == :internal_error

        render_error(error: 'validation_failed', errors: result.errors, status: :unprocessable_entity)
      end

      # Nothing was authorized: the refusal itself is the decision, and it comes
      # before there is a record to ask a policy about.
      def render_refusal(refusal)
        skip_authorization
        case refusal.code
        when :not_found then not_found
        when :forbidden then render_error(error: 'forbidden', reason: refusal.reason, status: :forbidden)
        when :invalid_input
          render_error(error: 'validation_failed', errors: [refusal_message(refusal)], reason: refusal.reason,
                       status: :unprocessable_entity)
        else
          render_error(error: refusal.reason, message: refusal_message(refusal), status: :unprocessable_entity)
        end
      end

      def refusal_message(refusal)
        I18n.t("services.meetings.intake.#{refusal.reason}")
      end

      # The participants pass by hand: permit drops a value of the wrong shape,
      # and a meeting silently without them reads like a meeting without them.
      # Meetings::Intake refuses what is no list of objects.
      def meeting_input
        input = params.require(:meeting)
        raise ActionController::ParameterMissing, :meeting unless input.is_a?(ActionController::Parameters)

        fields = input.permit(:project_id, *Meetings::Intake::FIELDS).to_h
        fields[:participants] = participant_rows(input[:participants]) if input.key?(:participants)
        fields
      end

      def participant_rows(raw)
        return raw unless raw.is_a?(Array)

        raw.map { |row| row.is_a?(ActionController::Parameters) ? row.permit(:display_name, :ref).to_h : row }
      end
    end
  end
end
