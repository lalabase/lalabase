# frozen_string_literal: true

# S3a T2: messages in an org-wide personal thread. The write gate is
# ChatPolicy#update? (owner + assistant pair), and there is no project door: a
# thread carries no project (DB invariant).
#
# It began as a mirror of the per-project surface removed by projekt_chat_abbau,
# and BORROWED that controller's error-status map plus its two turbo-stream
# templates. Step 2.5 of the cut moved all three here, so the deletion in step 3
# had nothing left to take away.
module Organisations
  class AssistantChatpostsController < Organisations::BaseController
    include AiFeatureGate

    # Maps Actors::RegenerateChatpost failure codes to the HTTP statuses the old
    # inline pre-checks produced (bare heads). #103 pattern, local like
    # Api::V1::TicketsController::ACTOR_ERROR_STATUS. :internal_error (BaseActor's
    # production mapping for unexpected errors) must stay a 5xx -- a server fault
    # reported as 422 would be invisible to error-rate monitoring.
    REGENERATE_ERROR_STATUS = {
      not_found: :not_found,
      not_regenerable: :unprocessable_entity,
      internal_error: :internal_server_error
    }.freeze

    before_action :set_chat
    before_action :ensure_ai_enabled, only: %i[create regenerate]

    # POST /org/:organisation_id/assistant_chats/:assistant_chat_id/chatposts
    def create
      authorize @chat, :update?

      result = Actors::CreateChatpost.call(chat: @chat, params: chatpost_params, current_user: current_user)
      @chatpost = result.resource

      if result.success?
        respond_to do |format|
          format.turbo_stream { render :create }
          format.html { redirect_to panel_path }
        end
      else
        composer = Neo::Chat::ComposerComponent.new(
          chat: @chat, chatpost: @chatpost, current_organisation: @current_organisation
        )
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace(@chat.chatpost_form_dom_id, render_to_string(composer, layout: false))
          end
          format.html do
            redirect_to panel_path,
                        alert: t('flash.chatposts.create_error')
          end
        end
      end
    end

    # POST /org/:organisation_id/assistant_chats/:assistant_chat_id/chatposts/:id/regenerate
    def regenerate
      authorize @chat, :update?

      result = Actors::RegenerateChatpost.call(chat: @chat, chatpost_id: params[:id], current_user: current_user)

      return head REGENERATE_ERROR_STATUS.fetch(result.code, :unprocessable_entity) unless result.success?

      head :no_content
    end

    # DELETE /org/:organisation_id/assistant_chats/:assistant_chat_id/chatposts/:id
    def destroy
      authorize @chat, :update?

      @chatpost = @chat.chatposts.find(params[:id])

      # The write-path twin of the component's show_delete? rule (T2 second
      # review, "the rule lived only in the view"): deleting the FIRST post of
      # an org thread would leave a thread that violates its own
      # chatposts-presence validation -- and here the empty thread would be the
      # whole surface.
      if @chatpost.is_first?
        return redirect_to panel_path,
                           alert: t('flash.chatposts.first_post_undeletable')
      end

      if @chatpost.destroy
        respond_to do |format|
          format.html do
            redirect_to panel_path, notice: t('flash.chatposts.deleted')
          end
          format.turbo_stream { render :destroy }
        end
      else
        redirect_to panel_path, alert: t('flash.chatposts.delete_error')
      end
    end

    private

    # Owner-scoped like AssistantChatsController#set_chat (same oracle argument,
    # same 404 for foreign and made-up ids); org_threads keeps the R-M7 door.
    def set_chat
      @chat = Chat.org_threads.where(user_id: current_user.id).find(params[:assistant_chat_id])
    end

    # T4: the thread has no page of its own any more. Every non-Turbo answer of
    # this controller lands where the panel is, carrying the thread so it reopens
    # on the right conversation. ONE helper rather than five call sites, because
    # five hand-written copies is how the last two of them stayed on the old
    # route through this very review.
    def panel_path
      # Two different right answers, because a redirect means two different things
      # here. Followed inside the panel's turbo frame, Turbo renders the target
      # with the bare turbo_rails/frame layout -- the org root has no
      # assistant_panel_body in that layout, so the frame ends up showing
      # "Content missing" and the alert is gone. The frame endpoint DOES render
      # that frame (including the reason, when the AI route is missing). A real
      # browser navigation, on the other hand, must not land on a bare fragment.
      if turbo_frame_request?
        organisation_assistant_panel_path(organisation_id: @current_organisation.id, chat_id: @chat.id)
      else
        organisation_root_path(organisation_id: @current_organisation.id, assistant_chat_id: @chat.id)
      end
    end

    def ai_disabled_redirect_path
      panel_path
    end

    def chatpost_params
      params.require(:chatpost).permit(:content, :revision_answer_id, :revision_answer_key, :ticket_suggestion_meeting_id)
    end
  end
end
