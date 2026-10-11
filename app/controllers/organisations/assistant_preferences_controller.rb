# frozen_string_literal: true

# The assistant's own settings (gear icon in the panel header): today exactly one
# setting, the standing persona this person's assistant answers with.
#
# Pure state, like Organisations::ChatStylePreferencesController next to it: no AI
# call happens here, nothing is regenerated, no quota is spent. Choosing a persona
# says "for what I ask next"; re-running an existing answer with it is the separate,
# explicit regenerate action on the answer itself.
#
# A single-column write with no side effects, so it stays in the controller per the
# actor seam rule. Deliberately NOT a copy of Actors::SetChatStyle: mirroring an
# actor for symmetry is the "spiegelt/analog" warning signal, and the one thing that
# actor's shape was really carrying -- the race against the (organisation_id,
# user_id) unique index -- now lives in ChatStylePreference.row_for!, where both
# writers reach it.
module Organisations
  class AssistantPreferencesController < Organisations::BaseController
    # PATCH /org/:organisation_id/assistant_preference
    def update
      # The same door the panel and its history list go through (§13-2: operator
      # flag + use_assistant). The question this endpoint asks is "may you use the
      # assistant at all", and its answer for an org thread is create?. Asking a
      # narrower question here would let somebody without the assistant configure
      # a surface they cannot open.
      authorize Chat.new(user: current_user, organisation: @current_organisation), :create?

      persona_id = params.require(:chat_style_preference).permit(:prompt_persona_id)[:prompt_persona_id].presence

      # Checked against the SAME pool the picker offers, mirroring what
      # assistant_chats#update does for the scope chip. The model validation
      # refuses a foreign persona too (PromptPersonaSelectable), but that would
      # surface as a 500 through save!; this turns a crafted id into a 422 with the
      # control snapped back to what is actually stored. Both, because the model
      # rule has to hold for a console or an import as well.
      return render_refused unless persona_id.nil? || offered_ids.include?(persona_id)

      ChatStylePreference.set_persona!(
        user: current_user, organisation: @current_organisation, prompt_persona_id: persona_id
      )

      respond_to do |format|
        format.turbo_stream { render :update }
        format.html { redirect_back fallback_location: organisation_root_path(@current_organisation) }
      end
    end

    private

    # The SAME stream as the success path, only with a 422. An empty body would
    # leave the select showing the value that was just refused with nothing to say
    # it did not take -- and this is reachable without crafting anything: a persona
    # deactivated between the render and the change event lands here.
    def render_refused
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_content }
        format.html do
          redirect_back fallback_location: organisation_root_path(@current_organisation),
                        alert: t('flash.assistant_preferences.persona_error')
        end
      end
    end

    # The SAME expression the picker builds its options from (PromptPersona.pickable_for),
    # so the offered list and the accepted list cannot drift apart.
    def offered_ids
      @offered_ids ||= PromptPersona.pickable_for(@current_organisation).map(&:id)
    end
  end
end
