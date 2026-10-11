# frozen_string_literal: true

module Admin
  class ApplicationController < ActionController::Base
    layout 'admin/backend_application'

    # Skip acts_as_tenant for admin controllers since they operate across all tenants
    # Note: Admin-Models are configured without acts_as_tenant, so no special tenant handling needed

    include Admin::Authentication

    # :exception, and prepended so it runs BEFORE require_login. The bare call
    # meant :null_session, which only drops the session: require_login had
    # already cached the beuser, so a token-less write still ran as the admin.
    # Mission Control inherits this through Admin::MissionControlController.
    # Pinned by spec/requests/admin/forgery_protection_spec.rb.
    protect_from_forgery with: :exception, prepend: true

    # A refused token means the form is stale more often than forged: signing in
    # to the app in the same browser rotates the token under an open admin tab.
    # Nothing has run yet, so a redirect with a message is as safe as Rails' bare
    # 422 page and tells the admin what to do.
    rescue_from ActionController::InvalidAuthenticityToken, with: :refuse_stale_form

    def redirect_to(*args)
      flash.keep
      super
    end

    def index
      redirect_to admin_dashboard_url
    end

    private

    # current_user, not logged_in?: Mission Control overrides logged_in? with its
    # own redirect. main_app: inside the engine the bare helpers are its routes.
    def refuse_stale_form
      target = current_user ? main_app.admin_dashboard_path : main_app.admin_log_in_path
      redirect_to target, alert: t('flash.admin.forgery.stale_form')
    end
  end
end
