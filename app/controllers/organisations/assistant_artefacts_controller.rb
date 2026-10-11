# frozen_string_literal: true

# S3c T3: the artefact lane of the assistant's full view (plan §4, §8.1).
#
# The lane is for content that has NO page of its own -- an evaluation, a hit
# list, later a draft. Objects that DO have a page keep opening the real app
# instead (a source chip navigates, and the full view steps back down to the
# companion mode so the navigation is visible).
#
# Two gates, deliberately one behind the other:
#
#   1. the assistant door, the same question the panel body asks -- may you use
#      the assistant in this organisation at all (§13-2 pair),
#   2. the PANEL's own check, because the kinds differ in what they show. A
#      report over booked time cannot be gated by the content-area table: that
#      table answers "may see time sessions" and cannot tell own from all
#      (§13-9). So each kind carries its own check and the registry is the list
#      of kinds that have one.
#
# Everything in the address is client-settable. Nothing here trusts it: an
# unknown kind, a foreign project and a project without a time permission all
# end in the SAME refusal, so the lane never reports whether something exists.
module Organisations
  class AssistantArtefactsController < Organisations::BaseController
    layout false

    # GET /org/:organisation_id/assistant_artefact
    #
    # Params:
    #   kind -- which panel kind (Assistant::PanelRegistry); unknown => refusal
    #   plus whatever the kind needs (report: project_id and the frozen filters
    #   of the citation)
    def show
      authorize Chat.new(user: current_user, organisation: @current_organisation), :create?

      kind = Assistant::PanelRegistry.canonical_kind(params[:kind])
      return render(:unavailable) if kind.nil?

      @panel = Assistant::PanelRegistry.panel_for(kind).call(
        user: current_user, organisation: @current_organisation, params: artefact_params
      )
      return render(:unavailable) unless @panel.available?

      # The template name is the REGISTRY's spelling of the kind, never the
      # parameter's -- `render params[:kind]` would be a render target chosen by
      # the caller.
      render kind
    end

    private

    # An explicit list rather than the raw params hash: the panel objects read
    # their arguments by key, and handing them the whole request means the next
    # one silently gains access to whatever else happens to be in there.
    def artefact_params
      params.permit(:project_id, :start_date, :end_date, :creator_id, :ticket_id)
            .to_h.symbolize_keys
    end
  end
end
