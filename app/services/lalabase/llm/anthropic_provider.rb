# frozen_string_literal: true

require 'anthropic'
require 'json'

module Lalabase
  module Llm
    class AnthropicProvider < Provider
      DEFAULT_CHAT_MODEL = 'claude-haiku-4-5-20251001'

      # Hard bound on the connectivity probe so a hanging endpoint cannot stall
      # the synchronous "test connection" request. Mirrors
      # GoogleVertexProvider::MINT_TIMEOUT_SECONDS.
      PROBE_TIMEOUT_SECONDS = 10

      # Anthropic stop_reason → canonical (OpenAI-flavoured) vocabulary used
      # by the Runner. Keeping the mapping in one place prevents the Runner
      # from hard-coding two provider dialects (`tool_use` vs `tool_calls`,
      # `end_turn` vs `stop`, etc.).
      STOP_REASON_MAP = {
        'end_turn' => 'stop',
        'stop_sequence' => 'stop',
        'max_tokens' => 'length',
        'tool_use' => 'tool_calls'
      }.freeze

      def default_chat_model
        configured_chat_model.presence || DEFAULT_CHAT_MODEL
      end

      def chat(messages:, tools: nil, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {})
        model ||= default_chat_model
        system_prompt, conversation = split_system(messages)
        params = build_params(model:, conversation:, system_prompt:, max_tokens:, temperature:, provider_options:)
        params[:tools] = tools.map { |t| anthropic_tool_schema(t) } if tools.present?

        response = client.messages.create(params)
        text_parts, tool_calls = extract_content_blocks(response)
        content_text = text_parts.join.strip
        raise Error, 'Anthropic returned empty content' if content_text.empty? && tool_calls.empty?

        {
          content: content_text,
          tool_calls: tool_calls.empty? ? nil : tool_calls,
          stop_reason: extract_stop_reason(response),
          model_used: model,
          token_usage: extract_token_usage(response, model: model)
        }
      rescue Anthropic::Errors::APIError => e
        raise mapped_error(e)
      end

      def stream_chat(messages:, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {}, &on_chunk)
        raise ArgumentError, 'stream_chat requires a block' unless block_given?

        model ||= default_chat_model
        system_prompt, conversation = split_system(messages)
        params = build_params(model:, conversation:, system_prompt:, max_tokens:, temperature:, provider_options:)

        start_time = Time.current
        captured_content = +''
        stream = client.messages.stream(params)

        stream.text.each do |delta|
          next if delta.blank?

          captured_content << delta
          on_chunk.call(delta)
        end

        final_message = stream.accumulated_message
        {
          content: captured_content,
          model_used: model,
          token_usage: extract_token_usage(final_message, model: model, start_time: start_time)
        }
      rescue Anthropic::Errors::APIError => e
        raise mapped_error(e)
      end

      # Token-free auth probe: GET /v1/models validates the key against
      # Anthropic's backend and spends no inference tokens.
      #
      # This used to be `api_key.present?`, with a comment claiming no cheap
      # endpoint existed. It does (gem >= 1.13 exposes client.models), and the
      # stub meant the admin "test connection" button reported success for any
      # non-empty string. Verified against the live endpoint: an invalid key
      # answers 401 → Anthropic::Errors::AuthenticationError, not an empty 200,
      # so a bare round-trip without an error IS the signal.
      #
      # The explicit timeout matters: the SDK default is minutes, far too long
      # for a synchronous diagnostic button (same reasoning as the Vertex
      # provider's MINT_TIMEOUT_SECONDS).
      def connectivity_check
        client.models.list(limit: 1, request_options: { timeout: PROBE_TIMEOUT_SECONDS })
        true
      rescue Anthropic::Errors::APIError => e
        raise mapped_error(e)
      end

      private

      def client
        @client ||= Anthropic::Client.new(api_key: api_key)
      end

      def build_params(model:, conversation:, system_prompt:, max_tokens:, temperature:, provider_options: {})
        params = {
          model: model,
          messages: translate_messages_for_anthropic(conversation),
          max_tokens: max_tokens,
          temperature: temperature
        }
        params[:system_] = system_prompt if system_prompt
        # Anthropic-appropriate extras (top_p, top_k, stop_sequences, …) pass through;
        # openai-only knobs (presence_penalty, …) would be rejected by the API, so the
        # caller is responsible for sending provider-appropriate options.
        params.merge(provider_options.to_h.symbolize_keys)
      end

      def anthropic_tool_schema(tool)
        {
          name: tool[:name],
          description: tool[:description],
          input_schema: tool[:input_schema]
        }
      end

      # Translates the provider-neutral canonical message form into Anthropic's
      # wire shape.
      #
      # Enforces the API's strict bundling rules: tool_result blocks MUST
      # follow an assistant turn that contained the matching tool_use blocks.
      # Orphan tool_result (no preceding assistant-with-tool_calls) AND split
      # bundles (assistant-with-tool_calls → tool → non-tool → tool) both
      # raise Provider::Error before the Anthropic API can reject them with
      # an opaque 400 — fail fast with an actionable message.
      def translate_messages_for_anthropic(conversation)
        result = []
        pending_tool_results = []
        expecting_tool_results = false

        conversation.each_with_index do |msg, idx|
          if msg[:role].to_s == 'tool'
            unless expecting_tool_results
              raise Provider::Error,
                    "Anthropic translator: orphan/split tool_result at index #{idx} " \
                    '(no preceding assistant-with-tool_calls, or batch already consumed)'
            end
            pending_tool_results << anthropic_tool_result_block(msg)
            next
          end

          unless pending_tool_results.empty?
            result << { role: 'user', content: pending_tool_results }
            pending_tool_results = []
          end

          # Any non-tool message resets the expectation. A subsequent tool-role
          # would now be an orphan (caught above on the next iteration). This
          # closes the split-bundle pattern: assistant-with-tool_calls → tool →
          # ANY non-tool → tool → ERROR.
          expecting_tool_results = false

          result << translate_non_tool_message(msg)

          expecting_tool_results = true if assistant_with_tool_calls?(msg)
        end

        result << { role: 'user', content: pending_tool_results } unless pending_tool_results.empty?

        result
      end

      def translate_non_tool_message(msg)
        return { role: msg[:role], content: msg[:content] } unless assistant_with_tool_calls?(msg)

        content_blocks = []
        # M3 + R2-3: coerce content for the text-block wrap using the SAME
        # serialiser as tool_result content (L4) — Hash/Array become JSON
        # instead of Ruby's #inspect output. Defends against a re-fed
        # already-translated assistant turn.
        content_blocks << { type: 'text', text: coerce_to_text(msg[:content]) } if msg[:content].present?
        msg[:tool_calls].each do |tc|
          content_blocks << {
            type: 'tool_use',
            id: tc[:id],
            name: tc[:name],
            input: tc[:args] || {}
          }
        end
        { role: 'assistant', content: content_blocks }
      end

      # assistant_with_tool_calls? (M4 semantics: tool_calls [] == nil) and
      # coerce_to_text (L4/M3: Hash/Array → JSON, not #inspect) moved to the
      # Provider base with the Gemini slice — both translators share them.

      def anthropic_tool_result_block(msg)
        tool_call_id = msg[:tool_call_id].to_s # L3: coerce Symbol → String
        # R2-2: nil/empty tool_call_id would emit tool_use_id: "" and 400 on
        # the wire. Fail fast with the offending message — symmetric with
        # M1's outbound id/name validation.
        if tool_call_id.empty?
          raise Provider::Error,
                "Anthropic translator: tool message missing tool_call_id (#{msg.inspect[0, 120]})"
        end

        block = {
          type: 'tool_result',
          tool_use_id: tool_call_id,
          content: coerce_to_text(msg[:content])
        }
        # L1: when the canonical message marks the tool as errored, propagate
        # is_error: true so Claude can reason about the failure instead of
        # treating the string literally.
        block[:is_error] = true if msg[:is_error]
        block
      end

      def extract_content_blocks(response)
        text_parts = []
        tool_calls = []
        Array(response.content).each do |block|
          case block_type(block)
          when 'text'     then text_parts << block_text(block).to_s
          when 'tool_use' then tool_calls << canonical_tool_call(block)
          else log_unknown_block_type(block)
          end
        end
        [text_parts, tool_calls]
      end

      # L2: silent drops of new content-block types (thinking, server_tool_use,
      # …) are invisible in production telemetry. A debug-level log gives us
      # a paper trail without spamming info/warn.
      def log_unknown_block_type(block)
        Rails.logger.debug do
          'Lalabase::Llm::AnthropicProvider: dropping unknown content block ' \
            "type=#{block_type(block).inspect} class=#{block.class}"
        end
      end

      # Anthropic SDK can present blocks as objects (block.type) or hashes
      # (block[:type] / block['type']). Normalise to a downcased String.
      def block_type(block)
        raw = if block.respond_to?(:type)
                block.type
              elsif block.respond_to?(:[])
                block[:type] || block['type']
              end
        raw.to_s
      end

      def block_text(block)
        return block.text if block.respond_to?(:text)

        block[:text] || block['text']
      end

      def canonical_tool_call(block)
        id    = block.respond_to?(:id)    ? block.id    : (block[:id]    || block['id'])
        name  = block.respond_to?(:name)  ? block.name  : (block[:name]  || block['name'])
        input = block.respond_to?(:input) ? block.input : (block[:input] || block['input'])

        # M1: missing id/name now means the Runner would later send a
        # tool_result with nil tool_use_id and the API would 400 far from the
        # actual cause. Fail fast with the offending block details.
        if id.to_s.empty? || name.to_s.empty?
          raise Provider::Error,
                "Anthropic returned malformed tool_use block (id=#{id.inspect}, name=#{name.inspect})"
        end

        { id: id.to_s, name: name.to_s, args: hash_input(input) }
      end

      # M2: input.to_h may return a non-Hash (Struct → Hash, custom #to_h that
      # returns Array, etc.). Verify the result really is a Hash; fall back
      # to {} rather than letting non-Hash garbage poison the Runner.
      def hash_input(input)
        return input if input.is_a?(Hash)
        return {} if input.nil?

        if input.respond_to?(:to_h)
          coerced = begin
            input.to_h
          rescue StandardError
            nil
          end
          return coerced if coerced.is_a?(Hash)
        end

        {}
      end

      # Vendor SDK error → our canonical provider error. One place so a new SDK
      # call only needs `rescue ... => e; raise mapped_error(e)` and can't
      # silently diverge the mapping. Unrecognised errors propagate unchanged.
      def mapped_error(error)
        case error
        when Anthropic::Errors::AuthenticationError then AuthError.new(error.message)
        when Anthropic::Errors::RateLimitError      then RateLimitError.new(error.message)
        # 400/403/404/422: the request arrived and was refused. Measured on prod
        # 2026-08-06 with an exhausted prepaid balance — Anthropic answers 400 with a
        # message naming exactly what to do, and every one of these classes used to
        # travel past all five of ChatResponseJob's provider rescues into its
        # StandardError arm, where the member is told "an unexpected error occurred".
        when Anthropic::Errors::BadRequestError,
             Anthropic::Errors::PermissionDeniedError,
             Anthropic::Errors::NotFoundError,
             Anthropic::Errors::UnprocessableEntityError then RequestRefusedError.new(error.message)
        # Transport and 5xx: genuinely transient, and the caller's copy for them
        # ("try again later") is honest. Mapped for the same reason as the group
        # above — unmapped they are indistinguishable from a bug in our own code.
        when Anthropic::Errors::APIConnectionError,
             Anthropic::Errors::InternalServerError then Error.new(error.message)
        else error
        end
      end

      # H2: normalise to canonical vocabulary so the Runner doesn't need to
      # know provider dialects. Shared fetch logic lives in Provider#normalise_stop_reason.
      def extract_stop_reason(response)
        raw = response.respond_to?(:stop_reason) ? response.stop_reason : nil
        normalise_stop_reason(raw)
      end

      def extract_token_usage(message_or_response, model:, start_time: nil)
        usage = message_or_response.respond_to?(:usage) ? message_or_response.usage : nil
        input  = usage&.input_tokens.to_i
        output = usage&.output_tokens.to_i
        # Cost is computed centrally by Lalabase::Llm::CostCalculator at tracking time
        # (from the credential price fields); the provider no longer prices tokens.
        duration_ms = start_time ? ((Time.current - start_time) * 1000).round : nil
        Lalabase::Llm::TokenUsage.build(
          input_tokens: input, output_tokens: output, cost_cents: 0,
          model: model, estimated: false, duration_ms: duration_ms
        )
      end
    end
  end
end
