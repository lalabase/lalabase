# frozen_string_literal: true

require 'openai'

module Lalabase
  module Llm
    class OpenAiProvider < Provider
      DEFAULT_CHAT_MODEL      = 'gpt-4o-mini'
      # System-wide embedding default. text-embedding-3-small is ~5x cheaper than
      # the former ada-002 ($0.02 vs $0.10 / 1M tokens), scores slightly higher on
      # MTEB, and returns 1536 dims natively — so it drops straight into the
      # existing vector(1536) columns/indexes with no schema change, only a
      # re-index (ada-002 vectors live in an incompatible space). This constant is
      # the single lever for the openai provider: #embed / #embed_batch default to
      # it, and #default_embedding_model (the provenance stamp) reads it too.
      DEFAULT_EMBEDDING_MODEL = 'text-embedding-3-small'

      # Rough chars→tokens heuristic for the streaming fallback estimate.
      # Deliberate duplication with GoogleVertexProvider::CHARS_PER_TOKEN (same
      # twin comment there) — unify in the base class at the third occurrence.
      CHARS_PER_TOKEN = 4.0

      # Embedding models that do NOT accept the `dimensions:` request parameter
      # (Matryoshka output truncation, doc/embedding_v2_multidim_plan.md §3.2).
      # Only the legacy ada-002 rejects it (400); text-embedding-3-* accept it, as
      # do OpenAI-compatible endpoints that opt in — so this is a blocklist, not an
      # allowlist. #embedding_parameters sends `dimensions:` only when a dim is
      # EXPLICITLY configured AND the model matches no marker here; with no configured
      # dim nothing is sent and the request is byte-identical to pre-v2.
      #
      # Matched as SUBSTRING markers, not exact model names (PR 5, review #350
      # follow-up): the exact match let Azure deployment aliases through
      # (`ada-002-prod`, `my-ada-002`) and sent them a param they 400 on. The
      # misclassification risk is asymmetrically small — a wrongly suppressed
      # `dimensions:` ends at worst as a loud DimensionMismatchError, a wrongly sent
      # one as a loud 400, and nobody names a 3-family deployment "ada-002".
      EMBEDDING_DIMS_UNSUPPORTED_MODEL_MARKERS = %w[ada-002].freeze

      # Reasoning models (gpt-5*, o1/o3/o4…) speak a different wire dialect than the
      # chat-completions models: they require `max_completion_tokens` (NOT
      # `max_tokens`) and reject any `temperature` other than the default. chat_parameters
      # branches on this so the ONE seam can drive both families (e.g. the customer
      # description generator's gpt-5-nano, migrated onto this seam in S2).
      REASONING_MODEL_PATTERN = /\A(?:gpt-5|o[1-9])/i

      # max_tokens is the budget of the ANSWER (Provider#chat contract). A
      # reasoning model spends its reasoning tokens out of max_completion_tokens
      # as well, so with the bare limit the reasoning can use it all and leave an
      # empty or cut answer. The reserve goes on top; a caller that sets
      # max_completion_tokens in provider_options still wins.
      REASONING_RESERVE = 4_096

      # OpenAI's finish_reason is already close to the canonical vocabulary
      # (stop / length / tool_calls / content_filter). The only legacy quirk
      # is `function_call` (predecessor of tool_calls) — normalise so the
      # Runner only ever sees one identifier for "model wants to call a tool".
      STOP_REASON_MAP = {
        'function_call' => 'tool_calls'
      }.freeze

      # Canonical name "openai" — NOT the auto-derived "open_ai". This must match
      # the Factory key, the AiCredential.provider value, and the schema default
      # for embedding_provider, because it is BOTH the provenance stamp
      # (EmbeddingColumns) AND the key for chat credential/usage resolution
      # (chat_response_job). The derived "open_ai" silently broke BYOK matching
      # and produced 'open_ai' provenance that no AiCredential ever matched.
      def self.provider_name
        ::AiCredential::PROVIDER_OPENAI
      end

      # Embedding-capable (see Provider.supports_embeddings?); inherited by
      # OpenAiCompatibleProvider. The base embed path here runs the dimension guard
      # (Provider#guard_dimensions, configured dim or default 1536) on every returned
      # vector, so both OpenAI's own and an inheriting provider's are checked.
      def self.supports_embeddings?
        true
      end

      def default_chat_model
        configured_chat_model.presence || DEFAULT_CHAT_MODEL
      end

      def default_embedding_model
        DEFAULT_EMBEDDING_MODEL
      end

      def chat(messages:, tools: nil, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {})
        model ||= default_chat_model
        params = chat_parameters(messages: translate_messages(messages), model:, max_tokens:, temperature:,
                                 provider_options:)
        params[:tools] = tools.map { |t| openai_tool_schema(t) } if tools.present?

        response = client.chat(parameters: params)
        msg = response.dig('choices', 0, 'message') || {}
        content = msg['content']
        raw_tool_calls = Array(msg['tool_calls'])

        result = {
          content: content.to_s.strip,
          tool_calls: raw_tool_calls.empty? ? nil : raw_tool_calls.map { |tc| parse_tool_call(tc) },
          stop_reason: normalise_stop_reason(response.dig('choices', 0, 'finish_reason')),
          model_used: model,
          token_usage: extract_token_usage(response, model: model)
        }
        if content.nil? && raw_tool_calls.empty?
          message = "OpenAI returned empty response: #{response.inspect}"
          # Stopped at the limit before any text: see Provider::TruncatedError.
          raise TruncatedError.new(message, result: result) if result[:stop_reason] == 'length'

          raise Error, message
        end

        result
      rescue Faraday::UnauthorizedError, Faraday::TooManyRequestsError, Faraday::BadRequestError => e
        raise mapped_error(e)
      end

      def stream_chat(messages:, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {}, &on_chunk)
        raise ArgumentError, 'stream_chat requires a block' unless block_given?

        # stream_chat is called by Tools::Runner only for the *final* turn (no tools
        # parameter) — but the message history may already contain tool-call /
        # tool-result entries from earlier iterations and needs to be translated
        # into OpenAI wire format.
        messages = translate_messages(messages)

        model ||= default_chat_model
        start_time = Time.current
        estimated_input = estimate_tokens(messages.sum { |m| m[:content].to_s.length })
        estimated_output = 0
        captured_content = +''
        real_usage = nil

        # ruby-openai's to_json_stream calls this proc with a SINGLE argument (the
        # parsed JSON chunk), NOT (chunk, bytesize). A strict 2-arg lambda raised
        # ArgumentError "given 1, expected 2" on every streamed answer — a latent bug
        # the former ticket chat exposed (tool-free, removed in S4-T1; it ALWAYS streamed,
        # while a chat with tool rounds usually answers via the non-streaming #chat and
        # never hit this). The splat tolerates a single arg here and any arity drift
        # across gem versions.
        #
        # With stream_options.include_usage, OpenAI emits a FINAL chunk whose choices
        # array is empty but which carries the real token usage — capture it and
        # prefer it over the char-based estimate below.
        streaming_proc = lambda do |chunk, *|
          real_usage = chunk['usage'] if chunk['usage'].present?
          delta = chunk.dig('choices', 0, 'delta', 'content')
          if delta.present?
            captured_content << delta
            estimated_output += [delta.split.length, 1].max
            on_chunk.call(delta)
          end
        rescue StandardError => e
          Rails.logger.error "OpenAiProvider streaming error: #{e.message}"
        end

        params = chat_parameters(messages:, model:, max_tokens:, temperature:, provider_options:)
                 .merge(stream: streaming_proc, stream_options: { include_usage: true })
        client.chat(parameters: params)

        # Prefer the provider's real counts; fall back to the estimate when the
        # endpoint omits usage (older / non-conforming OpenAI-compatible servers).
        usage = if real_usage
                  build_usage(real_usage['prompt_tokens'].to_i, real_usage['completion_tokens'].to_i,
                              model, start_time, estimated: false)
                else
                  build_usage(estimated_input, estimated_output, model, start_time, estimated: true)
                end

        { content: captured_content, model_used: model, token_usage: usage }
      rescue Faraday::UnauthorizedError, Faraday::TooManyRequestsError, Faraday::BadRequestError => e
        raise mapped_error(e)
      end

      def embed(text:, model: nil)
        embed_with_usage(text: text, model: model)[:embedding]
      end

      # Metering variant (S3): returns the vector AND the API's total_tokens so the
      # caller can book credits. #embed delegates here, so there is ONE embeddings
      # API call site. Inherited by OpenAiCompatibleProvider.
      #
      # guard_dimensions runs on the returned vector (embedding v2 PR 2): EVERY
      # vector that reaches a store is dimension-checked here, at the base embed
      # path — not just at OpenAiCompatibleProvider / GoogleVertexProvider. With no
      # configured dim the expectation is the 1536 default, so the real OpenAI
      # endpoint (native 1536) passes byte-for-byte as before.
      def embed_with_usage(text:, model: nil)
        # default_embedding_model (not the constant) so OpenAiCompatibleProvider's
        # configured model is honoured when it inherits this method.
        model ||= default_embedding_model
        response = client.embeddings(parameters: embedding_parameters(model: model, input: text))
        result = {
          embedding: response.dig('data', 0, 'embedding'),
          total_tokens: response.dig('usage', 'total_tokens').to_i
        }
        guard_dimensions(result[:embedding])
        result
      rescue Faraday::UnauthorizedError, Faraday::TooManyRequestsError => e
        raise mapped_error(e)
      end

      # Metering variant of the batch path (KI-Pakete P4a+), in the same shape as
      # #embed_with_usage is to #embed: ONE request, the vectors AND the API's
      # total_tokens. The usage block was always in this response — nothing read
      # it, which is why the reindex was a blind cost path (plan §2.4 finding 1).
      #
      # #embed_batch delegates here (base class), so there is ONE embeddings batch
      # call site and an unmetered caller cannot route around the meter.
      #
      # OpenAI accepts an array as input and returns embeddings in the same order.
      # Returns as many vectors as +texts+, each dimension-guarded (embedding v2
      # PR 2) so a bulk write can't stamp a triple onto a mis-sized vector.
      def embed_batch_with_usage(texts:, model: nil)
        return { embeddings: [], total_tokens: 0 } if texts.empty?

        model ||= default_embedding_model
        response = client.embeddings(parameters: embedding_parameters(model: model, input: texts))
        data = response['data'] || []
        # API guarantees order matches input order — but be defensive and sort by index.
        sorted = data.sort_by { |row| row['index'].to_i }
        { embeddings: sorted.map { |row| row['embedding'] }.each { |vector| guard_dimensions(vector) },
          total_tokens: response.dig('usage', 'total_tokens').to_i }
      rescue Faraday::UnauthorizedError, Faraday::TooManyRequestsError => e
        raise mapped_error(e)
      end

      # Lightweight connectivity probe for the settings "test connection" button —
      # lists models (does NOT spend tokens). Returns true when the endpoint answers
      # with at least one model; maps auth/rate errors so the caller can surface them.
      def connectivity_check
        response = client.models.list
        response['data'].is_a?(Array) && response['data'].any?
      rescue Faraday::UnauthorizedError, Faraday::TooManyRequestsError => e
        raise mapped_error(e)
      end

      private

      # Builds the embeddings request params, appending `dimensions:` only when a
      # dim is EXPLICITLY configured and the model accepts it (see #send_dimensions?).
      # Shared by #embed_with_usage and #embed_batch so both call sites agree.
      def embedding_parameters(model:, input:)
        params = { model: model, input: input }
        params[:dimensions] = configured_embedding_dims if send_dimensions?(model)
        params
      end

      # Send the Matryoshka `dimensions:` param only when a dim is EXPLICITLY
      # configured (configured_embedding_dims present) AND the model carries no
      # blocklist marker. With no configured dim the request stays byte-identical
      # to pre-v2 (no dimensions key), which keeps PR 1 behaviour-neutral.
      #
      # Overridden in OpenAiCompatibleProvider (PR 5): a third-party endpoint gets
      # the param only on explicit opt-in.
      def send_dimensions?(model)
        configured_embedding_dims.present? && !blocklisted_for_dimensions?(model)
      end

      def blocklisted_for_dimensions?(model)
        name = model.to_s
        EMBEDDING_DIMS_UNSUPPORTED_MODEL_MARKERS.any? { |marker| name.include?(marker) }
      end

      # Vendor HTTP error → our canonical provider error. One place so a new
      # client call only needs `rescue ... => e; raise mapped_error(e)` and can't
      # silently diverge the mapping. Anything we don't recognise propagates
      # unchanged (returned as-is, then re-raised by the caller).
      def mapped_error(error)
        case error
        when Faraday::UnauthorizedError    then AuthError.new(error.message)
        when Faraday::TooManyRequestsError then RateLimitError.new(error.message)
        # The endpoint refused what we asked for (max_tokens above the model's
        # output limit, prompt + max_tokens beyond its context): see RequestRefusedError.
        when Faraday::BadRequestError      then RequestRefusedError.new(error.message)
        else error
        end
      end

      def client
        @client ||= OpenAI::Client.new(
          access_token: api_key,
          organization_id: organisation_id_param.presence
        )
      end

      def chat_parameters(messages:, model:, max_tokens:, temperature:, provider_options: {})
        params = { model: model, messages: messages, n: 1 }
        if reasoning_model?(model)
          # gpt-5 / o-series: max_completion_tokens (not max_tokens), and temperature
          # must stay at the model's default — omit it entirely.
          params[:max_completion_tokens] = max_tokens + REASONING_RESERVE
        else
          params[:max_tokens] = max_tokens
          params[:temperature] = temperature
        end
        # provider_options (e.g. presence_penalty, reasoning_effort) merged last so a
        # caller can pass model-specific knobs the seam doesn't model explicitly.
        params.merge(provider_options.to_h.symbolize_keys)
      end

      def reasoning_model?(model)
        REASONING_MODEL_PATTERN.match?(model.to_s)
      end

      def extract_token_usage(response, model:)
        usage = response['usage'] || {}
        input  = usage['prompt_tokens']     || 0
        output = usage['completion_tokens'] || 0
        build_usage(input, output, model, nil, estimated: false)
      end

      def build_usage(input_tokens, output_tokens, model, start_time, estimated:)
        # Cost is no longer computed in the provider — Lalabase::Llm::CostCalculator is
        # the single source (from the credential price fields), applied at tracking
        # time. cost_cents stays in the shape (0) to satisfy the exact-key contract.
        duration_ms = start_time ? ((Time.current - start_time) * 1000).round : nil
        Lalabase::Llm::TokenUsage.build(
          input_tokens: input_tokens, output_tokens: output_tokens, cost_cents: 0,
          model: model, estimated: estimated, duration_ms: duration_ms
        )
      end

      def estimate_tokens(char_count)
        (char_count / CHARS_PER_TOKEN).round
      end

      # Most canonical messages pass through unchanged (OpenAI natively supports
      # `role: 'system'|'user'|'assistant'|'tool'`). Only the assistant-with-
      # tool_calls form needs rewrapping into OpenAI's function-call envelope
      # (each call wrapped in {id, type:'function', function: {name, arguments: <JSON-string>}}).
      #
      # We do NOT compact away `content: nil` — OpenAI's API expects the
      # `content` key to be present (nullable) on every assistant turn, and
      # the plan §5.2 explicitly specifies `content: nil` for tool-call turns.
      # Stripping the key risks rejection by stricter API validators.
      def translate_messages(messages)
        messages.map do |m|
          next m unless m[:role].to_s == 'assistant' && m[:tool_calls].present?

          {
            role: 'assistant',
            content: m[:content],
            tool_calls: m[:tool_calls].map { |tc| openai_tool_call_envelope(tc) }
          }
        end
      end

      def openai_tool_schema(tool)
        {
          type: 'function',
          function: {
            name: tool[:name],
            description: tool[:description],
            parameters: tool[:input_schema]
          }
        }
      end

      def openai_tool_call_envelope(tool_call)
        {
          id: tool_call[:id],
          type: 'function',
          function: {
            name: tool_call[:name],
            arguments: JSON.generate(tool_call[:args] || {})
          }
        }
      end

      # M1-parity with AnthropicProvider: missing id or name is fail-fast.
      # Without this, a nil id reaches the Runner, comes back as
      # tool_call_id: nil, and 400s on the next round-trip far from the
      # actual cause.
      def parse_tool_call(raw_tc)
        id   = raw_tc['id']
        name = raw_tc.dig('function', 'name')
        if id.to_s.empty? || name.to_s.empty?
          raise Error,
                "OpenAI returned malformed tool_call (id=#{id.inspect}, name=#{name.inspect})"
        end

        # Defensive parse: OpenAI guarantees `function.arguments` is a JSON-encoded
        # string, but the model occasionally emits malformed JSON. Swallow the
        # parse error and surface empty args — the tool's own validation then
        # reports "missing required arg" via the normal Result#error path.
        args_str = raw_tc.dig('function', 'arguments').to_s
        args = begin
          JSON.parse(args_str)
        rescue JSON::ParserError
          {}
        end
        { id: id.to_s, name: name.to_s, args: args }
      end
    end
  end
end
