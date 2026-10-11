# frozen_string_literal: true

module Api
  module V1
    # Whoami endpoint — returns identity + token scope.
    # Useful for checking whether a token works and which permissions it has.
    class MeController < BaseController
      # Deliberate opt-out from the Pundit tripwire: pure whoami endpoint —
      # identity and scope come directly from the authenticated token,
      # there is no foreign record object to authorize.
      skip_after_action :verify_authorized

      def show
        render json: {
          data: {
            user: serialize_user(current_user),
            token: serialize_token(current_token),
            scoped_organisations: serialize_scoped_organisations(current_token)
          }
        }
      end

      private

      def serialize_user(user)
        {
          id: user.id,
          email: user.email,
          display_name: user.display_name
        }
      end

      def serialize_token(token)
        {
          id: token.id,
          name: token.name,
          prefix: token.token_prefix,
          all_organisations: token.all_organisations?,
          # Whether a write (an MCP tool marked mutating) is refused for this token,
          # so a client knows before it offers one (terminal client plan, S0 b).
          read_only: token.read_only?,
          expires_at: token.expires_at.iso8601,
          last_used_at: token.last_used_at&.iso8601
        }
      end

      # The organisations the token reaches right now (PersonalAccessToken#organisation_scopes),
      # not the links it was made with: until 2026-10-02 this also named an organisation the
      # owner had been deactivated in.
      def serialize_scoped_organisations(token)
        scopes = token.organisation_scopes
        names = Organisation.where(id: scopes.map(&:organisation_id)).pluck(:id, :name).to_h
        scopes.map do |scope|
          payload = {
            id: scope.organisation_id,
            name: names[scope.organisation_id],
            all_projects: scope.all_projects?
          }
          payload[:scoped_project_ids] = token.linked_project_ids(scope.organisation_id) unless scope.all_projects?
          payload
        end
      end
    end
  end
end
