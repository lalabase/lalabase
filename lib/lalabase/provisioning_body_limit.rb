# frozen_string_literal: true

module Lalabase
  # Rejects an oversized provisioning body before anything reads it.
  #
  # A before_action cannot do this. ActionController::Instrumentation builds its
  # payload from request.filtered_parameters, which parses the body BEFORE the
  # first callback runs: measured with a probe on the JSON parser, an
  # unauthenticated 17 KB body was parsed in full and only then answered with
  # 401. A limit checked in a callback describes a rule it does not enforce.
  #
  # Content-Length is the caller's claim and not a measurement. It is what a
  # check in front of the parser can read; the hard limit for a body that lies
  # about its size belongs to nginx (client_max_body_size).
  #
  # Sits in front of Rack::MethodOverride, which reads the form body of every
  # POST looking for _method. That is the earliest point where the body is
  # touched; behind it, "unread" is not true for a form-encoded request. The
  # price is that Rack::Attack, further down, never counts a rejected request.
  # Worth it: the rejection reads one header and no body.
  class ProvisioningBodyLimit
    PATH_PREFIX = '/api/provisioning/'
    BODY = { error: { code: 'body_too_large', messages: [] } }.to_json

    def initialize(app, limit:)
      @app = app
      @limit = limit
    end

    def call(env)
      return @app.call(env) unless oversized?(env)

      [413,
       { 'content-type' => 'application/json', 'content-length' => BODY.bytesize.to_s },
       [BODY]]
    end

    private

    # Normalized like every throttle in rack_attack.rb: Rails routes
    # //api/provisioning/v1/signups to the same action, so a raw prefix test
    # would hand a padded path straight to the parser.
    def oversized?(env)
      return false unless env['CONTENT_LENGTH'].to_i > @limit

      ActionDispatch::Journey::Router::Utils
        .normalize_path(env['PATH_INFO'].to_s)
        .start_with?(PATH_PREFIX)
    end
  end
end
