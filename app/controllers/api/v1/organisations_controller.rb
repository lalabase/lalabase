# frozen_string_literal: true

module Api
  module V1
    class OrganisationsController < BaseController
      # Deliberate opt-out from the Pundit tripwire: the list is doubly filtered
      # by active membership + token scope — that IS the
      # authorization of this endpoint.
      skip_after_action :verify_policy_scoped

      def index
        # The organisations the token reaches right now (PersonalAccessToken#organisation_scopes:
        # token scope AND active membership, or every active membership for an all-organisations
        # token), in the order of the org switcher (Organisation.by_name).
        scopes = current_token.organisation_scopes.index_by(&:organisation_id)
        organisations = Organisation.where(id: scopes.keys).by_name

        render json: { data: organisations.map { |org| serialize(org, scopes.fetch(org.id)) } }
      end

      private

      def serialize(org, scope)
        {
          id: org.id,
          name: org.name,
          subdomain: org.subdomain,
          scope: scope.all_projects? ? 'all_projects' : 'selected_projects'
        }
      end
    end
  end
end
