# frozen_string_literal: true

module Api
  module Provisioning
    # API-only base for the calls the separate website makes into the core
    # (website split, step W2.3). One shared secret authenticates the website,
    # never a personal access token: a PAT belongs to a user with organisation
    # scopes, and this caller is a server acting for a visitor who has no
    # account yet.
    #
    # Everything here runs before the endpoint sees a parameter: absent when
    # unconfigured, and authenticated. The size limit is NOT here. The body is
    # already parsed by the time a callback runs, so it lives one layer out, in
    # Lalabase::ProvisioningBodyLimit.
    class BaseController < ActionController::API
      before_action :ensure_provisioning_enabled
      before_action :authenticate_website

      private

      def provisioning_configuration
        Rails.configuration.x.provisioning
      end

      # 404, not 403: an instance without a secret has no such endpoint, and
      # says so the way it says it about any other address.
      def ensure_provisioning_enabled
        render_error(:not_found, :not_found) unless provisioning_configuration.enabled?
      end

      def authenticate_website
        return if provisioning_configuration.authenticated?(presented_secret)

        render_error(:unauthorized, :unauthorized)
      end

      def presented_secret
        authorization = request.authorization.to_s
        return unless authorization.start_with?('Bearer ')

        authorization.delete_prefix('Bearer ')
      end

      def visitor_ip
        request.headers[Lalabase::ProvisioningConfiguration::VISITOR_IP_HEADER].presence
      end

      def visitor_user_agent
        request.headers[Lalabase::ProvisioningConfiguration::VISITOR_USER_AGENT_HEADER].presence
      end

      # Same envelope as the public API: one top-level key, so a consumer
      # branches on the key it got rather than on the shape it guessed.
      def render_error(status, code, messages: [])
        render json: { error: { code: code.to_s, messages: Array(messages) } }, status: status
      end
    end
  end
end
