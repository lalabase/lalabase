# frozen_string_literal: true

module Api
  module V1
    # Idempotency-Key on /api/v1 writes (cli_rest_plan D7): a client retrying a
    # write after a timeout sends the same key and gets the first answer back,
    # status and body, instead of a second comment or a second booking.
    #
    # Same table and store as the MCP writes (Mcp::IdempotencyStore), so keys
    # are per token. The fingerprint is method + path + parameters, never only
    # the parameters: an MCP call stores its tool arguments, so a key reused
    # across the two surfaces is a mismatch on either side and never replays the
    # other surface's answer.
    #
    # Runs as an around_action declared by the controller (`idempotent :create`),
    # so it sits INSIDE authentication and the read-only gate of
    # Api::V1::BaseController: a read-only token is refused before any replay,
    # and a replay goes to the token that stored it. Only a 2xx answer is
    # remembered; a refused write leaves the key free for the corrected retry.
    module Idempotent
      extend ActiveSupport::Concern

      HEADER = 'Idempotency-Key'
      MISMATCH = 'idempotency_key_reused'

      class_methods do
        def idempotent(*actions)
          around_action :with_idempotency_key, only: actions
        end
      end

      private

      def with_idempotency_key
        key = request.headers[HEADER].to_s.strip.presence
        return yield unless key

        store = Mcp::IdempotencyStore.new(token: current_token, tool_name: "rest:#{controller_path}##{action_name}",
                                          key: key, args: idempotency_fingerprint_args)
        stored = store.lookup
        return render_idempotency_mismatch if stored == :mismatch
        return replay_idempotent_answer(stored) if stored

        yield
        store.remember({ status: response.status, body: response.body }.to_json) if response.successful?
      end

      def idempotency_fingerprint_args
        { 'method' => request.request_method, 'path' => request.path,
          'params' => request.query_parameters.merge(request.request_parameters) }
      end

      # The stored body is the JSON string the first answer sent; rendered as is.
      # Nothing was authorized for this request, by design: the write it answers
      # for was, when it ran.
      def replay_idempotent_answer(record)
        answer = JSON.parse(record.response_content)
        skip_authorization
        render json: answer.fetch('body'), status: answer.fetch('status')
      end

      def render_idempotency_mismatch
        skip_authorization
        render_error(error: MISMATCH, code: 'invalid_input', message: Mcp::IdempotencyStore::MISMATCH_ERROR,
                     status: :unprocessable_entity)
      end
    end
  end
end
