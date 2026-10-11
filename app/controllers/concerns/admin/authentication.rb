# frozen_string_literal: true

module Admin
  module Authentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_user
      before_action :require_login
    end

    private

    def current_user
      return @current_user if defined?(@current_user)

      @current_user = session[:beuser_id].present? ? Beuser.find_by(id: session[:beuser_id]) : nil
    end

    def logged_in?
      current_user.present?
    end

    # D8/D4: authorization is re-checked on EVERY request, not just at login.
    # session[:beuser_id] is the admin session's OWN key, deliberately separate
    # from Devise's session[:user_id] (a User UUID) -- an app user who surfs to
    # /admin has no beuser_id and is simply redirected. Enforcing admin? && active
    # here (not only in SessionsController#create) throws out a beuser that was
    # deactivated or demoted mid-session on the next request.
    def require_login
      # logged_in? stays the first gate so Admin::MissionControlController's
      # override (which self-redirects for Mission-Control param quirks) still runs.
      return deny_admin_access unless logged_in?

      return if current_user.admin? && current_user.active?

      deny_admin_access
    end

    # Refuse admin access: drop ONLY the admin key and send the visitor to login.
    # Never reset_session here -- that would also destroy the Devise app session
    # of a signed-in user who merely visited /admin (drive-by logout, D8).
    # `unless performed?` covers the case where a logged_in? override (Mission
    # Control) has already redirected, so we do not render twice; on the
    # authorised-but-inactive path nothing has redirected yet, so it just runs.
    def deny_admin_access
      session.delete(:beuser_id)
      redirect_to(admin_log_in_path) unless performed?
    end
  end
end
