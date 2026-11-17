# frozen_string_literal: true

module Actors
  # Signs a device in: makes the access token of kind app_session that the
  # sign-in door of clients hands out, once the password was checked
  # (AppSessions::Authentication). current_user is the person just checked.
  #
  # One transaction: lock the account and make room (at most
  # PersonalAccessToken::MAX_APP_SESSIONS live devices, one more revokes the
  # device unused longest), create the token, note the login. The plaintext is
  # on #record (PersonalAccessToken#token) and nowhere else.
  #
  # The password was checked on the row as the caller read it. A new password
  # revokes every token of the account once, at the change, so under the lock
  # the actor asks whether the password is still the one that was checked and
  # refuses otherwise (code STALE_CREDENTIALS): a token written just after the
  # change would have outlived it.
  class CreateAppSession < BaseActor
    LOGIN_METHOD = 'app_session'
    STALE_CREDENTIALS = :stale_credentials

    def initialize(current_user:, device_name:, request: nil)
      super()
      @current_user = current_user
      @device_name = device_name
      @request = AppSessions::RequestFacts.wrap(request)
    end

    def perform
      PersonalAccessToken.make_room_for_app_session!(current_user)
      refuse_stale_credentials!
      @token = current_user.personal_access_tokens.new(
        kind: PersonalAccessToken::APP_SESSION,
        name: @device_name,
        all_organisations: true,
        read_only: false,
        expires_at: PersonalAccessToken::MAX_LIFETIME.from_now
      )
      @token.generate_token!
      current_user.track_login(request: @request, login_method: LOGIN_METHOD, device_name: @device_name)
    end

    def record
      @token
    end

    private

    # Runs under the lock of .make_room_for_app_session!, which a change of the
    # password waits for.
    def refuse_stale_credentials!
      return if User.where(id: current_user.id).pick(:encrypted_password) == current_user.encrypted_password

      raise ActorError.new(I18n.t('devise.failure.invalid', authentication_keys: User.human_attribute_name(:email)),
                           code: STALE_CREDENTIALS)
    end
  end
end
