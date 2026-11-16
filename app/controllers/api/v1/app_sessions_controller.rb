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
    # that signs out and gets 401 is signed out. The Idempotency-Key is taken
    # like on every write and its answer is stored, but nobody can ask for it
    # again: the replay sits inside authentication, and the token no longer
    # passes that. So a retry after a lost answer reads 401, never a second 200.
    class AppSessionsController < BaseController
      idempotent :destroy

      def destroy
        authorize current_token, :destroy?
        result = Actors::RevokeAppSession.call(current_user: current_user, token: current_token, request: request)
        return render_error(error: 'internal_error', status: :internal_server_error) unless result.success?

        render json: { data: { revoked_at: result.resource.revoked_at.iso8601 } }
      end
    end
  end
end
