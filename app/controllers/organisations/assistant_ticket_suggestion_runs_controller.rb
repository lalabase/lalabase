# frozen_string_literal: true

module Organisations
  # HTTP-only results: each poll and action checks ownership and current rights.
  class AssistantTicketSuggestionRunsController < Organisations::BaseController
    rescue_from ActiveRecord::RecordNotFound do
      @run ? render_result(error: t('assistant_suggestions.unavailable'), status: :not_found) : render_unavailable(:not_found)
    end

    rescue_from Pundit::NotAuthorizedError do
      @run ? render_result(error: t('assistant_suggestions.unavailable'), status: :forbidden) : render_unavailable(:forbidden)
    end

    before_action :set_chat
    before_action :set_run

    def show
      authorize @chat, :show?
      @run.recover_failed_delivery! if @run.readable_by?(current_user)
      render partial: 'neo/chat/ticket_suggestion_run', locals: { run: @run, user: current_user }
    end

    def accept
      authorize @chat, :update?
      authorize @run.meeting, :update?
      return render_result(error: t('assistant_suggestions.unavailable'), status: :forbidden) unless @run.writable_by?(current_user) && ProjectPolicy.new(current_user, @run.meeting.project).area_access?(:tickets, :write)

      suggestion = @run.meeting_ticket_suggestions.find(params[:suggestion_id])
      result = Actors::AcceptTicketSuggestion.call(meeting: @run.meeting, suggestion: suggestion, current_user: current_user)
      render_result(error: result.success? ? nil : result.errors.to_sentence, announce: true,
                    refresh_links: result.success?)
    end

    def dismiss
      authorize @chat, :update?
      authorize @run.meeting, :update?
      return render_result(error: t('assistant_suggestions.unavailable'), status: :forbidden) unless @run.writable_by?(current_user)

      suggestion = @run.meeting_ticket_suggestions.find(params[:suggestion_id])
      suggestion.dismiss_if_open
      render_result(announce: true)
    end

    def retry
      authorize @chat, :update?
      authorize @run.meeting, :update?
      return render_result(error: t('assistant_suggestions.unavailable'), status: :forbidden) unless @run.writable_by?(current_user)
      return render_result(error: t('assistant_suggestions.retried'), status: :unprocessable_content) unless @run.retryable?

      # A retry creates its own visible attempt and keeps the original error history.
      # It may use the saved target even if the chips changed after the first start.
      result = Actors::RetryTicketSuggestionRun.call(run: @run, current_user: current_user)
      if result.success?
        render turbo_stream: [turbo_stream.replace(helpers.dom_id(@run), partial: 'neo/chat/ticket_suggestion_run', locals: { run: @run.reload, user: current_user }),
                              turbo_stream.append(@chat.chatposts_dom_id, render_to_string(Neo::Chat::MessageComponent.new(chatpost: result.resource, current_user: current_user, current_organisation: current_organisation)))]
      else
        render_result(error: result.errors.to_sentence)
      end
    end

    private

    def render_unavailable(status)
      id = "meeting_ticket_suggestion_run_#{params[:id]}"
      content = helpers.turbo_frame_tag(id) { helpers.tag.p(t('assistant_suggestions.unavailable'), role: 'alert') }
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace(id, html: content), status: status }
        format.html { render html: content, status: status }
      end
    end

    def set_chat
      @chat = Chat.org_threads.where(organisation: current_organisation, user: current_user).find(params[:assistant_chat_id])
    end

    def set_run
      @run = runs.find(params[:id])
    end

    def runs
      MeetingTicketSuggestionRun.includes(meeting_ticket_suggestions: { similar_ticket: :project, created_ticket: :project }).joins(:chatpost).where(chatposts: { chat_id: @chat.id })
    end

    def render_result(error: nil, status: :ok, announce: false, refresh_links: false)
      @run = runs.find(@run.id)
      render turbo_stream: turbo_stream.replace(helpers.dom_id(@run), partial: 'neo/chat/ticket_suggestion_run',
                                                                      locals: { run: @run, user: current_user, error: error,
                                                                                announce: announce,
                                                                                announce_links: refresh_links }), status: status
    rescue ActiveRecord::RecordNotFound
      render_unavailable(:not_found)
    end
  end
end
