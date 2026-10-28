# frozen_string_literal: true

module Api
  module V1
    # The ONE builder of every /api/v1 error body (cli_rest_plan D6). Guarded by
    # spec/architecture/api_v1_error_body_guard_spec.rb: no controller renders
    # its own error JSON.
    #
    # `error` keeps the value it always had (token clients read it) and the HTTP
    # status stays the caller's. New beside it: `code`, the MCP error vocabulary
    # (Lalabase::Tools::Result::ERROR_CODES), so a program branches on the same
    # five classes on both surfaces, plus `unauthorized`, which MCP never answers
    # as a tool result. Actor codes nobody mapped are `refused` and carry the old
    # value as `reason`, as an MCP refusal carries its sub-code.
    module ErrorBody
      CODE_FOR_ERROR = {
        'unauthorized' => 'unauthorized',
        'forbidden' => 'forbidden',
        'not_member' => 'forbidden',
        'not_found' => 'not_found',
        'bad_request' => 'invalid_input',
        'validation_failed' => 'invalid_input'
      }.freeze

      REFUSED = 'refused'

      # @param error [String, Symbol] the legacy `error` value, unchanged on the wire
      # @param code [String, nil] overrides the derived code (read_only)
      # @param extra [Hash] fields the endpoint always sent beside `error` (errors, message)
      def self.build(error:, code: nil, **extra)
        error = error.to_s
        derived = CODE_FOR_ERROR[error]
        body = { error: error, code: (code || derived || REFUSED).to_s }
        body[:reason] = error if code.nil? && derived.nil?
        body.merge(extra)
      end
    end
  end
end
