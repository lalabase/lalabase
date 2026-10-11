# frozen_string_literal: true

module Admin
  class SessionsController < ApplicationController
    layout 'application_sessionless'

    skip_before_action :require_login, only: %i[new create]

    # D10: brute-force brake on the most privileged login in the app -- without it
    # this would be the only login without one (mirrors users/sessions_controller.rb).
    # by: defaults to request.remote_ip.
    rate_limit to: 10, within: 3.minutes, only: :create,
               with: -> { redirect_to admin_log_in_path, alert: t('shared.errors.rate_limit') }

    def new; end

    def create
      beuser = Beuser.find_by(email: params[:email])

      # D4: `active` is enforced at login AND re-checked per request
      # (Admin::Authentication#require_login) -- a deactivated admin must not get in.
      if beuser&.authenticate(params[:password]) && beuser.admin? && beuser.active?
        # D5: session-fixation protection -- plain reset_session BEFORE the write,
        # only on a successful admin login. Accepted side effect: a Devise app
        # session in the same browser ends here.
        reset_session
        # D8: the admin session uses its OWN key, deliberately separate from
        # Devise's session[:user_id] (a User UUID, users/sessions_controller.rb).
        # The old shared key let an app-user UUID be read as a beuser id.
        session[:beuser_id] = beuser.id
        redirect_to admin_dashboard_path, notice: t('flash.admin.sessions.logged_in')
      else
        redirect_to admin_log_in_path, alert: t('flash.admin.sessions.invalid_credentials')
      end
    end

    def destroy
      # D8: clear only the admin key -- a Devise app session in the same browser
      # survives the admin logout (deliberately no reset_session here).
      session.delete(:beuser_id)
      redirect_to admin_log_in_path, notice: t('flash.admin.sessions.logged_out')
    end
  end
end
