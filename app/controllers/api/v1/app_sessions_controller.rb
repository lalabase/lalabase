# frozen_string_literal: true

module Api
  module V1
    # DELETE /api/v1/app_session: signs the caller out. It revokes the token the
    # request came with, a device token (kind app_session) or a personal one, and
    # no other: there is no id to name. Signing in is not here but at the door of
    # its own, /api/auth/v1, where nobody holds a token yet.
    #
    # A read-only token is stopped by the gate of the base like every write (403
    # read_only) and stays alive; its owner revokes it on the token page.
    #
    # A second call with the same token gets 401: the token is revoked. A client
    # that signs out and gets 401 is signed out.
    #
    # The Idempotency-Key works here as on every write: a retry with the same key
    # reads the first answer again. But this write revokes the token the retry
    # comes with, and the replay of the base sits behind authentication, where a
    # revoked token no longer passes. So this action, and no other, looks for its
    # stored answer first (#replay_stored_sign_out). It answers a revoked token
    # only with what that same token was told before, under the key it chose,
    # for the same request. Every other call with the token gets 401.
    class AppSessionsController < BaseController
      prepend_before_action :replay_stored_sign_out, only: :destroy
      idempotent :destroy

      def destroy
        authorize current_token, :destroy?
        result = Actors::RevokeAppSession.call(current_user: current_user, token: current_token, request: request)
        return render_error(error: 'internal_error', status: :internal_server_error) unless result.success?

        render json: { data: { revoked_at: result.resource.revoked_at.iso8601 } }
      end

      private

      # Runs before authentication, so it trusts nothing but the stored row: the
      # token must be revoked, the row must be this token's, under this key, of
      # this action and of the same request (method, path, parameters). Anything
      # else falls through to the ordinary way, which answers a revoked token 401.
      def replay_stored_sign_out
        key = Mcp::IdempotencyStore.client_key(request.headers[HEADER])
        return unless key && Mcp::IdempotencyStore.storable_key?(key)

        revoked = PersonalAccessToken.find_revoked(request.headers['Authorization']&.sub(/\ABearer /, ''))
        return unless revoked

        tool_name = "rest:#{controller_path}##{action_name}"
        stored = Mcp::IdempotencyStore.new(token: revoked, tool_name: tool_name, key: key,
                                           args: idempotency_fingerprint_args).lookup
        return unless stored.is_a?(McpIdempotencyKey) && stored.tool_name == tool_name

        replay_idempotent_answer(stored)
      end
    end
  end
end
