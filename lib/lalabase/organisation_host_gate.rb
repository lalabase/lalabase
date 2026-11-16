# frozen_string_literal: true

module Lalabase
  # Answers what an organisation subdomain is not for, before the request reaches a
  # controller (doc/org_subdomains_plan.md, S2). Everything else passes through, and the
  # controllers decide rights as they always did: the host grants nothing.
  #
  # * an unknown subdomain: 404, no redirect;
  # * an old subdomain an organisation still holds: a GET or HEAD goes to the same path
  #   on the organisation's host now, anything else is 404 (no session lives there);
  # * the current subdomain of an organisation: the doors that belong to the main host
  #   (API and MCP, webhooks, the admin, the health check) are 404 there. One door each.
  #   The account pages of Devise (/users) belong to the main host too, where a person
  #   signs in: a GET goes there, signing out stays here (it ends every host's session),
  #   anything else is 404.
  #
  # With organisation subdomains switched off, it does nothing.
  class OrganisationHostGate
    MAIN_HOST_ONLY = %r{\A/(?:api|admin|webhooks|rails/action_mailbox|up)(?:/|\.|\z)}
    ACCOUNT_PAGES = %r{\A/users(?:/|\.|\z)}
    SIGN_OUT = %r{\A/users/sign_out(?:\.|\z)}

    # The answer of Organisations::Hosts for this request, read again by the controller
    # (OrganisationHost) instead of asked twice.
    ENV_KEY = 'lalabase.organisation_host_place'

    NOT_FOUND = [404, { 'content-type' => 'text/plain; charset=utf-8' }, ['Not Found']].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless ::Organisations::Hosts.enabled?

      request = ActionDispatch::Request.new(env)
      place = ::Organisations::Hosts.call(host: request.host)
      env[ENV_KEY] = place

      case place.kind
      when :unknown then not_found
      when :held then held(request, place.organisation)
      when :current then organisation_host(request, env)
      else @app.call(env)
      end
    end

    private

    def organisation_host(request, env)
      path = request.path
      return not_found if path.match?(MAIN_HOST_ONLY)
      return @app.call(env) unless path.match?(ACCOUNT_PAGES)
      return @app.call(env) if path.match?(SIGN_OUT) && request.delete?
      return not_found unless request.get? || request.head?

      redirect("#{request.protocol}#{::Organisations::Hosts.parent_domain}#{request.port_string}#{request.fullpath}")
    end

    def redirect(target)
      [302, { 'location' => target, 'content-type' => 'text/plain; charset=utf-8' }, ['']]
    end

    def held(request, organisation)
      return not_found unless request.get? || request.head?

      redirect("#{request.protocol}#{::Organisations::Hosts.host_for(organisation)}" \
               "#{request.port_string}#{request.fullpath}")
    end

    def not_found
      status, headers, body = NOT_FOUND
      [status, headers.dup, body.dup]
    end
  end
end
