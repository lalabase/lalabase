# frozen_string_literal: true

require_relative 'body_limit'

module Lalabase
  # Rejects an oversized body at the sign-in door of clients (/api/auth/) before
  # anything reads it. Why this is a middleware and where it sits:
  # Lalabase::BodyLimit.
  #
  # The limit is the size the per-address brake reads (Rack::Attack
  # LOGIN_BODY_LIMIT): an address that sits behind the part the brake reads
  # would reach no bucket. A sign-in is two short fields and a device name.
  class AuthBodyLimit < BodyLimit
    PATH_PREFIX = '/api/auth/'
    MAX_BODY_BYTES = 4.kilobytes

    def initialize(app)
      super(app, path_prefix: PATH_PREFIX, limit: MAX_BODY_BYTES)
    end

    private

    # Built per rejection, not as a constant: Api::V1::ErrorBody is application
    # code and this file loads while the application boots.
    def rejection_body
      Api::V1::ErrorBody.build(error: 'body_too_large', code: 'invalid_input').to_json
    end
  end
end
