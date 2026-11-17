# frozen_string_literal: true

require_relative 'body_limit'

module Lalabase
  # Rejects an oversized provisioning body before anything reads it. Why this is
  # a middleware and where it sits: Lalabase::BodyLimit.
  class ProvisioningBodyLimit < BodyLimit
    PATH_PREFIX = '/api/provisioning/'
    BODY = { error: { code: 'body_too_large', messages: [] } }.to_json

    def initialize(app, limit:)
      super(app, path_prefix: PATH_PREFIX, limit: limit)
    end

    private

    def rejection_body
      BODY
    end
  end
end
