# frozen_string_literal: true

module Organisations
  # Explicit UI action: response text is loaded from the owned chat, never from params.
  class AssistantAnalysesController < Organisations::BaseController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: t('assistant_analysis.unavailable') }, status: :not_found
    end
    rescue_from Pundit::NotAuthorizedError do
      render json: { error: t('assistant_analysis.unavailable') }, status: :forbidden
    end

    def create
      chat = Chat.org_threads.where(user_id: current_user.id).find(params[:assistant_chat_id])
      authorize chat, :update?
      result = Actors::SaveAssistantAnalysis.call(
        chat: chat, answer_id: params[:chatpost_id], meeting_id: params[:meeting_id],
        title: params[:title], answer_key: params[:answer_key], current_user: current_user
      )
      if result.success?
        analysis = result.resource
        # meeting_id lets the open meeting page refresh its stored-analyses list
        # (assistant:analyses-changed); a repeated save names the ORIGINAL meeting.
        render json: { message: t('assistant_analysis.saved'), meeting_id: analysis.meeting_id,
                       url: organisation_project_meeting_path(current_organisation, analysis.meeting.project,
                                                              analysis.meeting, analysis_id: analysis.id,
                                                                                anchor: ActionView::RecordIdentifier.dom_id(analysis)) }
      else
        render json: { error: result.code == :internal_error ? t('assistant_analysis.error') : result.errors.first },
               status: result.code == :internal_error ? :internal_server_error : :unprocessable_content
      end
    end
  end
end
