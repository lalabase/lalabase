# frozen_string_literal: true

module Actors
  # Signs a token out: revokes the access token a request came with and notes
  # the logout. The sign-out of clients (DELETE /api/v1/app_session) calls it
  # with the token of the request, a device token or a personal one;
  # current_user is its owner.
  #
  # The token is the caller's own by construction: it authenticated the request.
  # A token of another account here is a mistake of the caller, never a case to
  # answer. So it raises when the actor is made, outside the error mapping of
  # #call, which would turn it into a polite failure in production.
  #
  # A token that is revoked already keeps its moment and is not noted again: two
  # calls that both read it before either wrote are one sign-out.
  class RevokeAppSession < BaseActor
    LOGOUT_TYPE = 'app_session'

    def initialize(current_user:, token:, request: nil)
      super()
      raise ArgumentError, 'the token belongs to another account' unless token.user_id == current_user.id

      @current_user = current_user
      @token = token
      @request = AppSessions::RequestFacts.wrap(request)
    end

    def perform
      return unless @token.revoke!

      current_user.track_logout(request: @request, logout_type: LOGOUT_TYPE, device_name: @token.name)
    end

    def record
      @token
    end
  end
end
