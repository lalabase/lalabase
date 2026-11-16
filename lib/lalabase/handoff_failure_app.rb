# frozen_string_literal: true

module Lalabase
  # Devise's answer to a request without a session, with one difference on an organisation
  # host (doc/org_subdomains_plan.md, S3): a page asked for there starts the login hand-off
  # instead of showing a sign-in form, because a person signs in on the main host only.
  # Everywhere else, and for anything but a GET, Devise answers as it always did.
  class HandoffFailureApp < Devise::FailureApp
    def redirect_url
      return super unless scope == :user && request.get? && organisation_host?

      to = attempted_path.presence || '/'
      Rails.application.routes.url_helpers.session_handoff_start_path(to: to)
    end

    private

    def organisation_host?
      ::Organisations::Hosts.enabled? && ::Organisations::Hosts.call(host: request.host).organisation_host?
    end
  end
end
