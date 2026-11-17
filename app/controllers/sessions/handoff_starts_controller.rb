# frozen_string_literal: true

module Sessions
  # GET /session/start on an organisation host (doc/org_subdomains_plan.md, S3): the first
  # step of the login hand-off. Puts a random state into this host's own cookie and sends
  # its digest to the main host, where the person is (or gets) signed in. Every rule about
  # the hand-off lives in Sessions::HostHandoff.
  class HandoffStartsController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :load_tenant_from_session
    skip_before_action :show_page_on_main_host
    before_action :organisation_host_only

    def show
      path = HostHandoff.safe_path(params[:to])
      return redirect_to(path) if user_signed_in?

      state = HostHandoff.new_secret
      cookies[HostHandoff.state_cookie_name] = {
        value: state, httponly: true, secure: Rails.application.config.force_ssl, same_site: :lax,
        expires: HostHandoff::STATE_VALID_FOR.from_now
      }
      redirect_to main_host_url(session_handoff_path(target: request.host, to: path, state: HostHandoff.digest(state))),
                  allow_other_host: true
    end
  end
end
