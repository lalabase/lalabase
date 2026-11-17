# frozen_string_literal: true

module Sessions
  # GET /session/claim on an organisation host (doc/org_subdomains_plan.md, S3): the last
  # step of the login hand-off. The token counts only with the state this browser put into
  # its own cookie at the start; any claim burns it. A refusal sends the person to the main
  # host, which knows whether they are signed in.
  class ClaimsController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :load_tenant_from_session
    skip_before_action :show_page_on_main_host
    before_action :organisation_host_only
    before_action :refuse_head

    def show
      name = HostHandoff.state_cookie_name
      state = cookies[name]
      cookies.delete(name, secure: Rails.application.config.force_ssl)

      claim = HostHandoff.claim(token: params[:token].to_s, host: request.host, state: state.to_s)
      return redirect_to(main_host_url('/'), allow_other_host: true) unless claim

      # A fresh session: nothing of a session that existed here before survives the sign-in.
      reset_session
      sign_in(:user, claim.user)
      redirect_to claim.path
    end
  end
end
