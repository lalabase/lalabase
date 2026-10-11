# frozen_string_literal: true

# app/controllers/users/sessions_controller.rb
module Users
  class SessionsController < Devise::SessionsController
    layout :determine_layout
    # The login form is CSRF-protected like every other form: a forged
    # cross-site login would sign the victim into an account someone else
    # controls. A form left open until its session changed (sign-out in another
    # tab, an expired cookie) carries a stale token; that visitor gets the form
    # again with a hint instead of an error page. Nothing is signed in either way.
    rescue_from ActionController::InvalidAuthenticityToken, with: :redirect_stale_login_form
    skip_before_action :load_tenant_from_session, only: %i[new create destroy]
    skip_before_action :require_no_authentication, only: [:new]

    rate_limit to: 50, within: 3.minutes, only: :create, with: -> { redirect_to new_user_session_url, alert: t('shared.errors.rate_limit') }

    def new
      # When a signed-in user tries to access the sign-in page
      if user_signed_in?
        # Check whether to redirect to the organisation selection
        if current_user.organisations.count > 1
          redirect_to select_organisation_path
        elsif current_user.organisations.count == 1
          redirect_to organisation_root_path(organisation_id: current_user.organisations.first.id)
        else
          flash[:notice] = t('flash.sessions.no_organisations')
          redirect_to root_path
        end
      else
        super
      end
    end

    def create
      # Track failed login attempt if authentication fails
      self.resource = warden.authenticate!(auth_options)

      super do |resource|
        if resource.persisted?
          # Track successful login
          resource.track_login(
            request: request,
            organisation: resource.organisations.first
          )

          if resource.organisations.count > 1
            # If the user has multiple organisations, redirect to the selection
            session[:user_id] = resource.id
            redirect_to select_organisation_path and return
          elsif resource.organisations.count == 1
            # If the user has only one organisation, set it directly
            set_current_organisation(resource.organisations.first)
          else
            # If the user has no organisation, show an error and sign out
            sign_out resource
            redirect_to new_user_session_path, alert: t('flash.sessions.no_organisation_found') and return
          end
        end
      end
    rescue Warden::Strategies::Base::AuthenticationError
      # Track failed login attempt
      email = params.dig(:user, :email)
      if email.present? && (user = User.find_by(email: email))
        user.track_failed_login(request: request, reason: 'Invalid password')
      end
      # Re-raise the exception to let Devise handle it normally
      raise
    end

    def destroy
      # Track logout activity before signing out
      current_user&.track_logout(request: request)

      # Remove the tenant ID from the session before the user is signed out
      session.delete(:current_organisation_id)
      ActsAsTenant.current_tenant = nil

      # Sign the user out and redirect to the home page
      super do
        redirect_to root_path and return
      end
    end

    private

    def determine_layout
      # Werkstatt split screen (design handoff 3a) for the sign-in form; the
      # create branch covers the re-render after a failed login.
      if devise_controller? && resource_name == :user && %w[new create].include?(action_name)
        'application_auth'
      else
        'application'
      end
    end

    def redirect_stale_login_form
      redirect_to new_user_session_path, alert: t('flash.sessions.form_expired')
    end

    def set_current_organisation(organisation)
      return unless organisation

      ActsAsTenant.current_tenant = organisation
      session[:current_organisation_id] = organisation.id
    end
  end
end
