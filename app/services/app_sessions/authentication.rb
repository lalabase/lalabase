# frozen_string_literal: true

# Checks an e-mail address and a password for the sign-in door of clients
# (POST /api/auth/v1/app_sessions) and says who signed in, or why nobody did.
#
# The door does not run through Warden, so this object asks Devise's own
# questions in Devise's order, and does by hand what Warden's hooks do for the
# web form:
#
# * An unknown address computes a password hash for nothing, like Devise's
#   strategy in paranoid mode, so it does not answer faster than a known one.
# * `valid_for_authentication?` counts a failed attempt and locks at the limit.
#   It is false for a wrong password AND for a locked account with the right
#   one, which counts as well. So a locked account always reads as
#   `invalid_credentials`: an answer of its own would let somebody test guessed
#   passwords while the lock is meant to stop exactly that.
# * Whether the account may sign in at all (confirmed, active) is asked only
#   after the right password, so only its owner learns that state.
# * A success resets the counter.
#
# A reason Devise names that this object does not know becomes
# `invalid_credentials`, never a new value: a client must not meet a reason it
# was never told about.
module AppSessions
  class Authentication
    INVALID_CREDENTIALS = :invalid_credentials
    # Devise's inactive_message => the reason this door names.
    INACTIVE_REASONS = {
      unconfirmed: :email_unconfirmed,
      account_deactivated: :account_deactivated
    }.freeze

    Result = Data.define(:user, :failure) do
      def success? = failure.nil?
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # @param email [String] as typed; Devise strips and downcases it
    # @param password [String]
    # @param request [ActionDispatch::Request, nil] for the activity log
    def initialize(email:, password:, request: nil)
      @email = email
      @password = password
      @request = request
    end

    def call
      user = User.find_for_database_authentication(email: @email)
      return unknown_account if user.nil? || user.system_account?
      return wrong_password(user) unless user.valid_for_authentication? { user.valid_password?(@password) }
      return not_allowed(user) unless user.active_for_authentication?

      user.reset_failed_attempts!
      Result.new(user: user, failure: nil)
    end

    private

    def unknown_account
      User.new.password = @password
      refused(INVALID_CREDENTIALS)
    end

    # A wrong password, or a locked account whatever the password.
    def wrong_password(user)
      user.track_failed_login(request: @request, reason: 'Invalid password')
      refused(INVALID_CREDENTIALS)
    end

    # The right password on an account that may not sign in right now.
    def not_allowed(user)
      reason = INACTIVE_REASONS.fetch(user.inactive_message, INVALID_CREDENTIALS)
      user.track_failed_login(request: @request, reason: reason.to_s.humanize)
      refused(reason)
    end

    def refused(reason)
      Result.new(user: nil, failure: reason)
    end
  end
end
