# frozen_string_literal: true

# S3a T2/T4: org-wide personal assistant threads (project-less chats, plan §6.1).
# Deliberately LEAN: no ProjectController
# stack (there is no project to load), the whole gate is ChatPolicy's org branch
# (ownership + the §13-2 assistant pair, no admin bypass).
#
# T4 took the SURFACE away from here. The assistant is a companion lane, not a
# navigation target (L11), so there is no second place where an org thread is
# rendered: the panel in the application layout is the only one. What is left in
# this controller are the writes and the doors in front of them.
module Organisations
  class AssistantChatsController < Organisations::BaseController
    include AiFeatureGate

    # A stale tab or crafted POST must not enqueue an LLM job while the org's AI
    # opt-in is off. destroy stays allowed -- deleting is local data.
    before_action :ensure_ai_enabled, only: %i[create]
    before_action :set_chat, only: %i[show update destroy]

    # GET /org/:organisation_id/assistant_chats/:id
    #
    # Not a page any more (L11): it hands the thread to the companion panel and
    # sends the user to a real place. That keeps shared and bookmarked links
    # working WITHOUT a second rendering of the same transcript, which would put
    # two identical chatposts containers on one document and let broadcasts land
    # in whichever one Turbo found first.
    #
    # The door above (set_chat + authorize) is unchanged and still runs first: a
    # foreign or made-up id gets its 404 here, not at the panel.
    def show
      authorize @chat, :show?

      redirect_to organisation_root_path(organisation_id: @current_organisation.id,
                                         assistant_chat_id: @chat.id)
    end

    # POST /org/:organisation_id/assistant_chats
    #
    # Creates an org-wide thread with its first message. The owner is forced
    # server-side in Actors::SaveChat; the stand-in here carries the asker so the
    # policy's owner check (create?) sees the record it will authorize.
    def create
      authorize Chat.new(user: current_user, organisation: @current_organisation), :create?

      submitted = chat_params
      result = Actors::SaveChat.call(params: submitted.except(:reference_keys), current_user: current_user,
                                     reference_keys: submitted[:reference_keys] || [])
      @chat = result.resource

      respond_to do |format|
        # The form lives inside the panel's turbo frame, so the answer is a
        # stream: `update` (not `replace`) keeps the frame ELEMENT and with it
        # the src the panel controller armed -- replacing it would leave a frame
        # that can no longer reload itself.
        # On failure @chat stays the INVALID record: the panel re-renders the
        # empty state with it, so the question the user typed comes back in the
        # field instead of being swallowed.
        format.turbo_stream { render :create, status: (result.success? ? :ok : :unprocessable_content) }
        format.html { redirect_after_create(result) }
      end
    end

    # PATCH /org/:organisation_id/assistant_chats/:id
    #
    # The SCOPE chip under the composer and nothing else: the standing narrowing
    # to ONE project (§9.3). A trivial single-column write with no side effects,
    # so this stays in the controller (Actor seam rule).
    #
    # The reference next door left with the Bezugs-Sammlung (S1, §7.2): a
    # collection write is lock plus discard plus limit, which the seam rule calls
    # non-trivial, and it lives in Actors::AddChatReference /
    # Actors::RemoveChatReference behind its own routes.
    #
    # The project is validated against Chats::AssistantScopeOptions -- the same
    # list the chip offers. Without that check a crafted id could pin the thread
    # to a project the user cannot see; Tools::Scope would refuse to honour it,
    # but the chip would still print its NAME, and a name is the one thing the
    # sidebar withholds from someone without access.
    def update
      authorize @chat, :update?

      changes = scope_changes
      return refuse_scope_change if changes.nil?

      @chat.update!(changes) if changes.any?

      respond_to do |format|
        format.turbo_stream { render :update }
        format.html { redirect_to panel_path }
      end
    end

    # DELETE /org/:organisation_id/assistant_chats/:id
    #
    # Through the actor like the project twin (seam rule): one transaction over
    # the chatposts cascade, and an unexpected mid-cascade error becomes a
    # failure alert instead of a 500 with a half-deleted thread.
    def destroy
      authorize @chat, :destroy?

      result = Actors::DestroyChat.call(chat: @chat, current_user: current_user)

      if result.success?
        redirect_to organisation_root_path(organisation_id: @current_organisation.id),
                    status: :see_other, notice: t('flash.assistant_chats.deleted')
      else
        redirect_to organisation_root_path(organisation_id: @current_organisation.id,
                                           assistant_chat_id: @chat.id),
                    alert: t('flash.assistant_chats.delete_error')
      end
    end

    private

    # Only what the request actually SENT, never a column it did not name. The
    # scope select submits its field alone and must not take the reference
    # collection down with it -- widening the reach is not the same act as
    # dropping the subject of the conversation, and the row re-renders either way,
    # so a silent extra write would only show up in the next answer.
    #
    # Answers the changes to write, or nil to refuse the whole request (see
    # #refuse_scope_change). An empty hash means nothing to write, which is what a
    # request naming no field at all is.
    def scope_changes
      submitted = params.require(:chat).permit(:scope_project_id)
      return {} unless submitted.key?(:scope_project_id)

      project_id = submitted[:scope_project_id].presence
      return nil unless scope_options.includes?(project_id)

      { scope_project_id: project_id }
    end

    # The SAME stream as the success path, only with a 422. An empty body would
    # leave the chip showing the value that was just refused, with nothing to
    # tell the user it did not take -- and this is reachable without crafting
    # anything: a project archived between the render and the change event lands
    # here. Re-rendering the row snaps it back to the resolved selection, which
    # is what the chips are for.
    #
    # ⚠️ And it SAYS so. The message used to sit in the format.html branch alone,
    # which a Turbo submit never reaches, so a refusal was a 422 carrying the
    # same stream as a success: the chip snapped back and nothing anywhere told
    # the user why. The reference's refusal moved with its write into
    # AssistantChatReferencesController#refuse (Bezugs-Sammlung S1); both render
    # the same template and both set the flash, so the row's two writers still
    # answer a refusal the same way.
    def refuse_scope_change
      message = t('flash.assistant_chats.scope_error')

      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = message
          render :update, status: :unprocessable_content
        end
        format.html { redirect_to panel_path, alert: message }
      end
    end

    def scope_options
      @scope_options ||= Chats::AssistantScopeOptions.new(user: current_user, organisation: @current_organisation)
    end

    # Where a non-Turbo answer of this controller lands. Same split as in
    # AssistantChatpostsController#panel_path: a 302 followed inside the panel
    # frame must land on something that CONTAINS that frame.
    def panel_path
      if turbo_frame_request?
        organisation_assistant_panel_path(organisation_id: @current_organisation.id, chat_id: @chat.id)
      else
        organisation_root_path(organisation_id: @current_organisation.id, assistant_chat_id: @chat.id)
      end
    end

    # Non-Turbo fallback (a form submitted without JavaScript). There is no page
    # for the thread any more, so success lands where the panel does.
    def redirect_after_create(result)
      if result.success?
        redirect_to organisation_root_path(organisation_id: @current_organisation.id,
                                           assistant_chat_id: @chat.id),
                    status: :see_other, notice: t('flash.assistant_chats.created')
      else
        redirect_back fallback_location: organisation_root_path(organisation_id: @current_organisation.id),
                      alert: @chat&.errors&.full_messages&.to_sentence.presence || t('flash.assistant_chats.create_error')
      end
    end

    # Tenant-scoped via acts_as_tenant; org_threads only -- project threads keep
    # their own door (R-M7). OWNER-scoped on purpose (T2 second
    # review): a foreign thread of the own org must answer the same 404 as a
    # made-up id, otherwise the response difference is an existence oracle on a
    # surface whose rule is "persoenlich ist persoenlich". The authorize calls
    # stay -- they gate the assistant pair (flag + permission) on records the
    # finder DID resolve, and they satisfy verify_authorized.
    def set_chat
      @chat = Chat.org_threads.where(user_id: current_user.id).find(params[:id])
    end

    # Same split as in AssistantChatpostsController#panel_path: a 302 followed
    # inside the panel frame must land on something that CONTAINS that frame,
    # otherwise Turbo renders "Content missing" and swallows the alert.
    def ai_disabled_redirect_path
      return organisation_assistant_panel_path(organisation_id: @current_organisation.id) if turbo_frame_request?

      organisation_root_path(organisation_id: @current_organisation.id)
    end

    # Same shape as chats#create: title/persona plus the first (nested) message.
    # Owner and post author are NOT permitted here -- SaveChat forces both.
    def chat_params
      params.require(:chat).permit(:title, :prompt_persona_id, reference_keys: [], chatposts_attributes: %i[content ticket_suggestion_meeting_id])
    end
  end
end
