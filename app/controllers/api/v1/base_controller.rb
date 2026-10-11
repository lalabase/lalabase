# frozen_string_literal: true

module Api
  module V1
    # Base for all /api/v1/* controllers.
    # ActionController::API → no view layer, no cookies, no CSRF.
    class BaseController < ActionController::API
      include Pundit::Authorization
      include Api::TokenAuthenticatable
      # ActiveStorage sets Current.url_options from a before_action that Rails only
      # installs on ActionController::Base. We inherit from ActionController::API, so
      # without this include `blob.url` raises ArgumentError ("please set
      # ActiveStorage::Current.url_options") on the Disk service — which is the service
      # production runs (config.active_storage.service = :local). The attachments
      # endpoint is the one that calls it, and its only test used to cover the EMPTY
      # list, so a 500 on every ticket that actually had a file stayed invisible.
      include ActiveStorage::SetCurrent

      # A read-only token (the default) may not write through any endpoint. Enforced
      # here, once, like Mcp::ToolCall#write_blocked? on the MCP seam, so a new write
      # endpoint cannot forget it. Runs after authenticate_with_token! (declared by the
      # concern above).
      before_action :refuse_write_with_read_only_token

      rescue_from Pundit::NotAuthorizedError, with: :forbidden
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActionController::ParameterMissing, with: :bad_request

      # Pundit tripwire (pattern: Organisations::BaseController): Every action must
      # authorize explicitly — authorize or policy_scope in index. A new
      # endpoint that forgets authorization fails loudly
      # (AuthorizationNotPerformedError → 500) instead of silently returning 200.
      # Controllers whose authorization is the token scope itself (me,
      # notifications, organisations) opt out via a commented skip_after_action.
      #
      # Lambda conditions instead of only:/except: — Rails 7.1+ raises with
      # raise_on_missing_callback_actions for only: :index on controllers
      # WITHOUT an index action (me, posts) ActionNotFound (= silent 404).
      after_action :verify_authorized, if: -> { action_name != 'index' }
      after_action :verify_policy_scoped, if: -> { action_name == 'index' }

      after_action :reset_current_attributes

      private

      def refuse_write_with_read_only_token
        forbidden if current_token.read_only? && !(request.get? || request.head?)
      end

      def forbidden
        render json: { error: 'forbidden' }, status: :forbidden
      end

      def not_found
        render json: { error: 'not_found' }, status: :not_found
      end

      def bad_request(exception)
        render json: { error: 'bad_request', message: exception.message }, status: :bad_request
      end

      def reset_current_attributes
        Current.reset
      end
    end
  end
end
