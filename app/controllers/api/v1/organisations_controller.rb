# frozen_string_literal: true

module Api
  module V1
    class OrganisationsController < BaseController
      # Deliberate opt-out from the Pundit tripwire: the list is doubly filtered
      # by active membership + token scope — that IS the
      # authorization of this endpoint.
      skip_after_action :verify_policy_scoped

      def index
        # The organisations the token reaches right now (token scope AND active
        # membership, or every active membership for an all-organisations token), in the
        # order of the org switcher. The reader is shared with the MCP tool list_organisations.
        render json: { data: PersonalAccessTokens::ReachListing.new(reach: current_token.reach).organisations }
      end
    end
  end
end
