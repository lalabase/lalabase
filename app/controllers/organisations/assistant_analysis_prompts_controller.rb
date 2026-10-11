# frozen_string_literal: true

module Organisations
  # Uses the existing organisation library and the meeting's read/write policies.
  class AssistantAnalysisPromptsController < Organisations::BaseController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: t('assistant_analysis.unavailable') }, status: :not_found
    end
    rescue_from Pundit::NotAuthorizedError do
      render json: { error: t('assistant_analysis.unavailable') }, status: :forbidden
    end

    before_action :set_meeting

    def show
      authorize @meeting, :update?
      render json: {
        prompts: AnalysisPrompt.where(organisation: current_organisation).order(:title).as_json(only: %i[id title prompt_text]),
        can_manage: MeetingPolicy.new(current_user, @meeting).update?,
        # Transitional response compatibility for assistant JavaScript already
        # open during a rolling deploy. Current assets manage templates inline;
        # old assets land on the saved-analysis section and can reopen the assistant.
        manage_url: organisation_project_meeting_path(
          current_organisation, @meeting.project, @meeting,
          anchor: helpers.meeting_analyses_frame_id(@meeting)
        )
      }
    end

    def create
      authorize @meeting, :update?
      prompt = AnalysisPrompt.new(params.require(:analysis_prompt).permit(:title, :prompt_text))
      prompt.organisation = current_organisation
      prompt.creator = current_user
      if prompt.save
        render json: { message: t('assistant_analysis.template_saved') }, status: :created
      else
        render json: { error: prompt.errors.full_messages.to_sentence }, status: :unprocessable_content
      end
    end

    def destroy
      authorize @meeting, :update?
      AnalysisPrompt.where(organisation: current_organisation).find(params.require(:prompt_id)).destroy!
      render json: { message: t('assistant_analysis.template_deleted') }
    end

    private

    def set_meeting
      authorize Chat.new(organisation: current_organisation, user: current_user), :create?
      @meeting = Meeting.where(organisation: current_organisation).find(params[:meeting_id])
    end
  end
end
