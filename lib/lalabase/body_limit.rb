# frozen_string_literal: true

module Lalabase
  # Rejects an oversized body under one path prefix before anything reads it.
  # A door names its prefix, its limit and its answer in a subclass
  # (ProvisioningBodyLimit, AuthBodyLimit).
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
  class BodyLimit
    def initialize(app, path_prefix:, limit:)
      @app = app
      @path_prefix = path_prefix
      @limit = limit
    end

    def call(env)
      return @app.call(env) unless oversized?(env)

      body = rejection_body
      [413, { 'content-type' => 'application/json', 'content-length' => body.bytesize.to_s }, [body]]
    end

    private

    # The JSON a rejected caller reads, in the envelope of its door.
    def rejection_body
      raise NotImplementedError, "#{self.class} must implement #rejection_body"
    end

    def oversized?(env)
      env['CONTENT_LENGTH'].to_i > @limit && under_prefix?(env)
    end

    # Normalized like every throttle in rack_attack.rb: Rails routes a padded
    # path (a doubled slash) to the same action, so a raw prefix test would hand
    # it straight to the parser.
    def under_prefix?(env)
      ActionDispatch::Journey::Router::Utils
        .normalize_path(env['PATH_INFO'].to_s)
        .start_with?(@path_prefix)
    end
  end
end
