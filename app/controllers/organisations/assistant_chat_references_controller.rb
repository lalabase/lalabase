# frozen_string_literal: true

# Bezugs-Sammlung S1 (plan §7.1): the write path of the reference collection.
# Deliberately lean, like the assistant controllers next to it: no project stack
# (there is no project), the writes themselves live in actors, and what is left
# here are the two doors in front of them.
#
# TWO gates, not one, because they are two different questions:
#   1. OWNER -- Chat.org_threads.where(user_id: current_user.id).find(...), word
#      for word like AssistantChatsController#set_chat. A foreign thread of one's
#      own organisation must answer the same 404 as a made-up id, or the
#      difference in the response is an existence oracle.
#   2. OBJECT -- Tools::Scope#resolve_reference, inside the actor, and nothing
#      else. "May this object stand on this thread?" has ONE owner; a second check
#      by hand here would be the duplicated enforcement §13-9 of the plan forbids.
module Organisations
  class AssistantChatReferencesController < Organisations::BaseController
    before_action :set_chat
    # §8.1: EVERY response of this controller redraws the chip row, and every one
    # of them is the outcome of a reference write -- so the collection comes back
    # unfolded. The cross of each entry sits inside the open list, and a list that
    # snaps shut after each write turns three removals into seven clicks. A
    # refusal counts too: the row is redrawn there as well, and closing it under
    # the user would read as a second thing that happened.
    #
    # Set HERE rather than in the two render helpers, because "a request to this
    # controller is a reference write" is a property of the controller, not of the
    # branch that happens to answer.
    before_action { @reference_expanded = true }

    # POST /org/:organisation_id/assistant_chats/:assistant_chat_id/references
    #
    # The body carries the KEY ("Ticket:<uuid>"), the same value the URL segment of
    # #destroy carries and the same one the chip publishes in data-reference-keys.
    # A pair here and a key there would be two parsers for one identity.
    #
    # ⚠️ The key never sees constantize. Only the registry lookup turns a string
    # into a type (Assistant::ReferenceRegistry.parse_key).
    def create
      authorize @chat, :update?

      reference = Assistant::ReferenceRegistry.parse_key(params[:key])
      return refuse if reference.nil?

      result = Actors::AddChatReference.call(chat: @chat, current_user: current_user, **reference)
      return refuse(error_message_for(result)) unless result.success?

      render_row
    end

    # DELETE /org/:organisation_id/assistant_chats/:assistant_chat_id/references/:key
    #
    # An unknown or no longer resolvable key is SUCCESS, so this action has exactly
    # one answer: the row, redrawn. See Actors::RemoveChatReference for why.
    #
    # ⚠️ What is NOT success is a write the thread could not SAVE -- a retired
    # persona fails every validation on it. That answers like every other refusal,
    # or the row would be drawn from the record the actor assigned to and show
    # the chip gone while the database keeps it.
    def destroy
      authorize @chat, :update?

      reference = Assistant::ReferenceRegistry.parse_key(params[:key])
      if reference
        result = Actors::RemoveChatReference.call(chat: @chat, current_user: current_user, **reference)
        return refuse(error_message_for(result)) unless result.success?
      end

      render_row
    end

    private

    # The SAME template as the chip row's other writer
    # (AssistantChatsController#update), rendered rather than copied: one write of
    # the row, one place where the flash is decided. A second template would be a
    # second copy of that render, and the two would drift the first time the row
    # learns something.
    def render_row
      respond_to do |format|
        format.turbo_stream { render template: 'organisations/assistant_chats/update' }
        format.html { redirect_to panel_path }
      end
    end

    # An empty 422 would leave the chip showing what was just refused with nothing
    # to say it did not take -- and this arrives without anybody crafting it: a
    # project archived between the render and the click lands here. So the refusal
    # answers with the same stream as the success path, which snaps the row back to
    # what actually resolves, AND it says why.
    def refuse(message = nil)
      message = message.presence || t('flash.assistant_chats.reference_error')
      # ⚠️ From the PERSISTED state. A failed update! rolls the transaction back
      # but leaves the assigned values on the record (Rails restores the dirty
      # bookkeeping, not the attributes), and a row rendered from that record
      # would show the write as landed: the new chip after a refused addition, no
      # chip after a refused removal. The reload is what makes "snaps the row back
      # to what actually resolves" true on every path, not only on the one where
      # the actor refused before assigning anything.
      @chat.reload

      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = message
          render template: 'organisations/assistant_chats/update', status: :unprocessable_content
        end
        format.html { redirect_to panel_path, alert: message }
      end
    end

    # The message a failed actor result may show. :internal_error carries the raw
    # exception text (BaseActor#handle_unexpected_error, production only): a lock
    # timeout on the row lock would put "SELECT chats.* ... FOR UPDATE" into the
    # panel, a thread deleted from a second tab "Couldn't find Chat with 'id'=".
    # So that code gets the generic sentence; a domain refusal and a validation
    # message pass through. Same masking as MeetingAnalysesController and
    # TimeSessionGroupsController -- and the third copy of it by hand.
    def error_message_for(result)
      return nil if result.code == :internal_error

      result.errors.to_sentence
    end

    # Same split as in the other assistant controllers: a 302 followed inside the
    # panel frame must land on something that CONTAINS that frame.
    def panel_path
      if turbo_frame_request?
        organisation_assistant_panel_path(organisation_id: @current_organisation.id, chat_id: @chat.id)
      else
        organisation_root_path(organisation_id: @current_organisation.id, assistant_chat_id: @chat.id)
      end
    end

    # Gate 1, see the class comment. Owner-scoped, org threads only.
    def set_chat
      @chat = Chat.org_threads.where(user_id: current_user.id).find(params[:assistant_chat_id])
    end
  end
end
