# frozen_string_literal: true

# Per-user chat answer-style level (ChatStylePreference): the style pills under
# the chat composer set ONE dimension (technicality / length) to an absolute
# level. Pure state — no AI call happens here, so this deliberately carries
# neither the KI opt-in gate nor a chat policy: storing a preference touches no
# chat content and costs no quota. Re-running an existing answer in the new style
# is the separate, fully gated regenerate action
# (Organisations::AssistantChatpostsController).
class Organisations::ChatStylePreferencesController < Organisations::BaseController
  # PATCH /org/:organisation_id/chat_style_preference?dimension=…&level=…
  def update
    authorize :chat_style_preference, :update?

    # Strictly the requesting user's own row in the current org (tenant is set by
    # BaseController#set_organisation). No params-driven user lookup → no
    # cross-user write. dimension/level are whitelisted in the actor (and again
    # in the model) — a crafted param can neither reach a foreign column nor
    # store a level the prompt lookup has no I18n key for.
    result = Actors::SetChatStyle.call(
      dimension: params[:dimension], level: params[:level],
      current_user: current_user, organisation: current_organisation
    )

    return head :unprocessable_entity unless result.success?

    respond_to do |format|
      # Re-renders the pill row in place, so the newly picked step is highlighted.
      format.turbo_stream
      format.html { redirect_back fallback_location: organisation_root_path(current_organisation) }
    end
  end
end
