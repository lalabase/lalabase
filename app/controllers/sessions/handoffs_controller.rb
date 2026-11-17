# frozen_string_literal: true

module Sessions
  # GET /session/handoff on the main host (doc/org_subdomains_plan.md, S3): the person is
  # signed in here (Devise sends them through the sign-in first and back), and a single-use
  # token for the asking organisation host goes back to it. The token carries the user, the
  # host, the path and the digest of the asking browser's state.
  class HandoffsController < ApplicationController
    # No tenant is needed, and the session's organisation must not redirect this step away.
    skip_before_action :load_tenant_from_session
    before_action :main_host_only
    before_action :refuse_head

    def show
      host = params[:target].to_s.downcase
      return head(:not_found) unless Organisations::Hosts.call(host: host).organisation_host?
      return head(:not_found) unless params[:state].to_s.match?(HostHandoff::DIGEST_FORMAT)

      token = HostHandoff.mint(user: current_user, host: host, path: params[:to], state_digest: params[:state])
      redirect_to "#{request.protocol}#{host}#{request.port_string}#{session_claim_path(token: token)}",
                  allow_other_host: true
    end
  end
end
