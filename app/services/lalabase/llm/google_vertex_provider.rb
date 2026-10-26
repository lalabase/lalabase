# frozen_string_literal: true

require 'faraday'
require 'googleauth'
require 'json'
require 'stringio'
require 'timeout'

# Entry point: chat (Provider interface: chat / stream_chat / embed_with_usage)
#
# Gemini via Vertex AI, spoken natively over REST (option 3a of
# doc/ki_provider_dsgvo_plan.md §5): Faraday + googleauth, no google-cloud
# SDK. Wire formats verified against the Vertex/Gemini API reference on
# 2026-07-17 (generateContent, streamGenerateContent?alt=sse, :predict).
#
# GDPR posture hangs on the REGIONAL endpoint:
# https://{location}-aiplatform.googleapis.com — an API key would silently
# route via the GLOBAL endpoint and void EU data residency, hence
# service-account auth ONLY. api_key carries the service-account JSON
# (stored in the encrypted access_token column — NEVER in the plaintext
# additional_config). project_id + location come from the credential's
# additional_config and are required; missing config fails fast and loud.
#
# Embeddings: gemini-embedding-001 embeds natively at 3072 and truncates via
# Matryoshka outputDimensionality to the configured dim (default 1536,
# doc/embedding_v2_multidim_plan.md §3.2) — the sovereign embedding path. The
# endpoint accepts a single instance per :predict call, so #embed_batch keeps
# the base-class one-call-per-text fallback.
module Lalabase
  module Llm
    class GoogleVertexProvider < Provider
      # gemini-2.5-flash answers 200 on EVERY EU single-region endpoint
      # (europe-west1/west3/west4/west9) and on global — countTokens
      # availability matrix of 2026-07-18, which also disproved the earlier
      # note here that newer Flash generations were multi-region-only. The
      # previous default (gemini-2.0-flash) has been retired and 404s
      # everywhere, so a credential WITHOUT an explicit default_model was dead
      # on arrival. Availability still shifts per region over time — re-check
      # with the admin availability probe before going live; the credential's
      # default_model overrides this.
      DEFAULT_CHAT_MODEL      = 'gemini-2.5-flash'
      DEFAULT_EMBEDDING_MODEL = 'gemini-embedding-001'

      TOKEN_SCOPE = 'https://www.googleapis.com/auth/cloud-platform'
      # Re-mint the OAuth token BEFORE it actually expires so it cannot lapse
      # mid-request. The freshness check runs per request (not per instance
      # lifetime) because one provider instance can outlive the ~1h token
      # during long streams (plan §9 risk 5).
      TOKEN_EXPIRY_BUFFER = 60 # seconds
      # Hard bound on the OAuth token mint so a hanging auth endpoint cannot
      # stall a synchronous request (e.g. the admin availability probe) forever.
      MINT_TIMEOUT_SECONDS = 10

      REQUEST_TIMEOUT_SECONDS = 120

      # Rough chars→tokens heuristic for the streaming fallback estimate.
      # Deliberate duplication with OpenAiProvider::CHARS_PER_TOKEN (same twin
      # comment there) — unify in the base class at the third occurrence.
      CHARS_PER_TOKEN = 4.0

      # max_tokens is the budget of the ANSWER (Provider#chat contract). Gemini
      # 2.5 Flash and Pro think before they answer, dynamically up to 8,192
      # tokens, and the thought tokens count against maxOutputTokens: with the
      # bare limit a short answer could be left with almost nothing, and a
      # longer one stopped half way. So these two families get a
      # fixed thinking budget and the same reserve on top of the answer budget.
      # 2,048 lies inside both accepted ranges (Pro 128..32,768, it cannot turn
      # thinking off; Flash 1..24,576).
      # Not matched on purpose: Flash-Lite (a budget would switch thinking on),
      # 2.0 Flash (no thinking) and Gemini 3 (thinkingLevel instead, and
      # thinkingBudget is deprecated there and can answer 400).
      THINKING_BUDGET = 2_048
      # Also not matched: the image, speech (tts), live and native-audio variants
      # of 2.5, which do not think, and a longer word after the family name.
      THINKING_MODEL_PATTERN = /\Agemini-2\.5-(?:pro|flash)(?:\z|-(?!.*(?:lite|image|tts|live|audio)))/

      # Gemini finishReason → canonical vocabulary (see Provider#chat). The
      # whole safety family collapses onto content_filter; unknown values pass
      # through so the Runner can log them. NB: Gemini reports STOP even for
      # tool-call turns — #extract_stop_reason derives 'tool_calls' from the
      # presence of functionCall parts instead.
      STOP_REASON_MAP = {
        'STOP' => 'stop',
        'MAX_TOKENS' => 'length',
        'SAFETY' => 'content_filter',
        'RECITATION' => 'content_filter',
        'BLOCKLIST' => 'content_filter',
        'PROHIBITED_CONTENT' => 'content_filter',
        'SPII' => 'content_filter'
      }.freeze

      SSE_EVENT_SEPARATOR = /\r?\n\r?\n/

      # Routing key stays 'google' — NOT the auto-derived 'google_vertex'. It
      # must match the Factory key, existing AiCredential.provider values, the
      # admin dropdown and the org ai_provider setting; the derived name would
      # orphan every existing 'google' reference. Vertex-vs-AI-Studio is an
      # implementation detail (and AI Studio is a GDPR non-option, see header).
      def self.provider_name
        ::AiCredential::PROVIDER_GOOGLE
      end

      # Embedding-capable (feeds the AiCredential purpose validation): the
      # 1536-truncated gemini-embedding-001 is precisely why this provider
      # carries the EU embedding story in v1.
      def self.supports_embeddings?
        true
      end

      # ---- shared auth/endpoint class API (shared with VertexAvailabilityProbe) --
      #
      # ONE owner for the service-account wire/auth format: the probe reuses
      # these instead of duplicating creds building, token minting and endpoint
      # construction. The instance methods below delegate here, so the existing
      # provider spec keeps pinning the runtime behaviour.

      # Builds googleauth credentials from a service-account JSON, mapping any
      # malformed input (or a legacy API key in the access_token column) to a
      # credential-shaped AuthError instead of an opaque JSON/Signet error.
      def self.build_service_account_credentials(sa_json)
        Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(sa_json.to_s),
          scope: TOKEN_SCOPE
        )
      rescue JSON::ParserError
        # A JSON parse error message echoes a fragment of the malformed input —
        # for a service-account JSON that leaks private-key material into the
        # AuthError (and from there into an admin flash / error monitoring).
        # Swallow the detail; the generic reason is all the operator needs.
        raise AuthError, 'google service account credentials invalid: malformed JSON'
      rescue StandardError => e
        # Non-parse failures (missing keys, Signet) carry no input fragment —
        # keep the detail, it is the actionable diagnostic.
        raise AuthError, "google service account credentials invalid: #{e.message}"
      end

      # One-shot token mint for callers without a provider instance (the
      # availability probe). The instance path keeps its own memoization +
      # expiry-buffer logic in #fresh_access_token.
      def self.mint_access_token(sa_json)
        creds = build_service_account_credentials(sa_json)
        Timeout.timeout(MINT_TIMEOUT_SECONDS) { creds.fetch_access_token! }
        creds.access_token
      rescue Signet::AuthorizationError => e
        raise AuthError, "google token mint failed: #{e.message}"
      rescue Faraday::Error, Timeout::Error, SocketError, SystemCallError => e
        # Transport failure / hang while reaching Google's auth backend. Map it
        # to AuthError so callers (controller, #test_connection) surface a flash
        # instead of a 500; the class alone is enough — no secret in it.
        raise AuthError, "google token mint failed (transport): #{e.class}"
      end

      # Deliberately UNGATED asymmetry: these two accept any location including
      # 'global'. The EU-residency guarantee lives in the instance #location
      # method (which rejects 'global' for every runtime call); the probe may
      # address 'global' informationally without weakening that runtime gate.
      def self.endpoint_host_for(location)
        "https://#{location}-aiplatform.googleapis.com"
      end

      def self.model_path_for(project_id:, location:, model:, action:)
        "/v1/projects/#{project_id}/locations/#{location}/publishers/google/models/#{model}:#{action}"
      end

      def default_chat_model
        configured_chat_model.presence || DEFAULT_CHAT_MODEL
      end

      # Constant wins deliberately (parity with OpenAiProvider): a google
      # credential's default_model is its CHAT model; honouring it here would
      # send :predict calls to a chat model for purpose=both credentials.
      def default_embedding_model
        DEFAULT_EMBEDDING_MODEL
      end

      def chat(messages:, tools: nil, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {})
        model ||= default_chat_model
        payload = build_generate_payload(messages: messages, tools: tools, model: model, max_tokens: max_tokens,
                                         temperature: temperature, provider_options: provider_options)
        response = post_json(model_path(model, :generateContent), payload)

        candidate = response.dig('candidates', 0) ||
                    raise(Error, "Vertex AI returned no candidates (promptFeedback: #{response['promptFeedback'].inspect})")
        text_parts, tool_calls = extract_parts(candidate)
        content_text = text_parts.join.strip
        stop_reason = extract_stop_reason(candidate, tool_calls)

        # An output-side safety/recitation block yields a candidate with a
        # content_filter finishReason and NO parts. Surface the contract's
        # first-class content_filter stop_reason (with empty content) instead of
        # a generic empty-content error, so the Runner can tell "policy-blocked"
        # from "genuinely empty" — a realistic EU content-policy case, and the
        # finishReason is right here on the candidate. Only a truly empty result
        # (no content, no tools, no filter signal) is an error — now carrying the
        # finishReason for diagnosis.
        result = {
          content: content_text,
          tool_calls: tool_calls.empty? ? nil : tool_calls,
          stop_reason: stop_reason,
          model_used: model,
          token_usage: usage_from_metadata(response['usageMetadata'], model: model)
        }
        if content_text.empty? && tool_calls.empty? && stop_reason != 'content_filter'
          finish = candidate['finishReason'].inspect
          message = "Vertex AI returned empty content (finishReason: #{finish})"
          # MAX_TOKENS with no text: the thoughts used the whole limit (the
          # thinking budget is a target, not a hard cap). See TruncatedError.
          raise TruncatedError.new(message, result: result) if stop_reason == 'length'

          raise Error, message
        end

        result
      end

      def stream_chat(messages:, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {}, &on_chunk)
        raise ArgumentError, 'stream_chat requires a block' unless block_given?

        model ||= default_chat_model
        payload = build_generate_payload(messages: messages, tools: nil, model: model, max_tokens: max_tokens,
                                         temperature: temperature, provider_options: provider_options)
        start_time = Time.current
        captured_content = +''
        usage_metadata = nil
        buffer = +''

        # Every complete SSE event is one GenerateContentResponse; the final
        # one carries the authoritative usageMetadata (prefer it over the
        # char-based estimate below — same pattern as OpenAiProvider).
        handle_event = lambda do |event|
          usage_metadata = event['usageMetadata'] if event['usageMetadata'].present?
          delta = extract_text_delta(event)
          next if delta.empty?

          captured_content << delta
          on_chunk.call(delta)
        end

        response = connection.post(model_path(model, :streamGenerateContent)) do |req|
          req.params['alt'] = 'sse'
          apply_json_headers(req)
          req.body = JSON.generate(payload)
          # Faraday's on_data yields raw byte chunks as they arrive. A proc
          # (not a strict lambda) tolerates adapters passing fewer args — the
          # same arity lesson as ruby-openai's stream proc (see OpenAiProvider).
          req.options.on_data = proc do |chunk, _received_bytes, env|
            buffer << chunk
            status = env&.status
            # A non-200 body is a plain JSON error, not SSE — keep it intact
            # in the buffer for the mapped error below.
            drain_sse_events(buffer, &handle_event) if status.nil? || status == 200
          end
        end
        raise_mapped_http_error(response.status, buffer) unless response.status == 200

        flush_sse_tail(buffer, &handle_event)

        usage = if usage_metadata
                  usage_from_metadata(usage_metadata, model: model, start_time: start_time)
                else
                  estimated_usage(messages, captured_content, model, start_time)
                end
        { content: captured_content, model_used: model, token_usage: usage }
      end

      def embed(text:, model: nil)
        embed_with_usage(text: text, model: model)[:embedding]
      end

      # Metering variant — the ONE embeddings call site (#embed delegates,
      # parity with OpenAiProvider). outputDimensionality is the CONFIGURED dim
      # when set, else the 1536 default (doc/embedding_v2_multidim_plan.md §3.2);
      # any Matryoshka-truncated output (i.e. any dim < the native 3072) is NOT
      # unit-normalised by the API, only the native 3072 is — so we normalise
      # client-side for EVERY configured dim (m4), otherwise cosine/inner-product
      # scores drift against the normalised vectors sharing the space.
      def embed_with_usage(text:, model: nil)
        model ||= default_embedding_model
        payload = {
          instances: [{ content: text }],
          parameters: { outputDimensionality: expected_embedding_dims }
        }
        response = post_json(model_path(model, :predict), payload)
        embeddings = response.dig('predictions', 0, 'embeddings') || {}
        vector = guard_dimensions(normalise_vector(Array(embeddings['values'])))
        { embedding: vector, total_tokens: embeddings.dig('statistics', 'token_count').to_i }
      end

      # A real, token-cost-free auth probe: minting the OAuth token round-trips
      # to Google's auth backend and validates the whole service-account JSON
      # including its private key — without touching a model.
      #
      # Deliberately the CLASS method, not #fresh_access_token: only the class
      # path carries MINT_TIMEOUT_SECONDS and the transport rescue
      # (Faraday/Timeout/SocketError). The instance path is memoised for real
      # requests and may block indefinitely if Google's auth backend hangs
      # rather than answering — unacceptable for a synchronous button that
      # holds a web worker. This also keeps the admin probe byte-identical to
      # the one VertexAvailabilityProbe uses on the same page.
      #
      # NB: this validates the service-account JSON only. project_id/location
      # are NOT exercised here — a credential with a typo'd project or region
      # still probes green; that question is what VertexAvailabilityProbe
      # answers.
      def connectivity_check
        self.class.mint_access_token(api_key).present?
      end

      private

      # ---- auth -----------------------------------------------------------

      def credentials
        @credentials ||= self.class.build_service_account_credentials(api_key)
      end

      # Returns a currently-valid OAuth2 access token, minting or re-minting
      # as needed. Called per request — see TOKEN_EXPIRY_BUFFER.
      def fresh_access_token
        creds = credentials
        creds.fetch_access_token! if creds.access_token.nil? || creds.expires_within?(TOKEN_EXPIRY_BUFFER)
        creds.access_token
      rescue Signet::AuthorizationError => e
        raise AuthError, "google token mint failed: #{e.message}"
      end

      # ---- configuration / endpoint ---------------------------------------

      # project_id + location are non-secret routing data from the credential's
      # additional_config (the JSON column is NOT encrypted; the SA JSON itself
      # lives in the encrypted access_token). Both are required: without an
      # explicit location there is no regional endpoint to promise.
      def project_id
        @project_id ||= required_config('project_id')
      end

      def location
        @location ||= begin
          value = required_config('location')
          if value == 'global'
            # The global endpoint is exactly the routing this provider exists
            # to prevent (plan §9 risk 2) — it voids EU data residency.
            raise Provider::Error,
                  "google provider: location 'global' voids data residency — " \
                  'configure a regional location (e.g. europe-west3)'
          end
          value
        end
      end

      def required_config(key)
        value = additional_config&.dig(key).to_s.strip
        if value.empty?
          raise Provider::Error,
                "google provider requires additional_config['#{key}'] — none configured " \
                '(set it on the AI credential in the admin backend)'
        end
        value
      end

      def endpoint_host
        self.class.endpoint_host_for(location)
      end

      def model_path(model, action)
        self.class.model_path_for(project_id: project_id, location: location, model: model, action: action)
      end

      # ---- HTTP -----------------------------------------------------------

      def connection
        @connection ||= Faraday.new(url: endpoint_host) do |conn|
          conn.options.timeout = REQUEST_TIMEOUT_SECONDS
        end
      end

      def post_json(path, payload)
        response = connection.post(path) do |req|
          apply_json_headers(req)
          req.body = JSON.generate(payload)
        end
        raise_mapped_http_error(response.status, response.body) unless response.status == 200
        JSON.parse(response.body)
      end

      def apply_json_headers(req)
        req.headers['Authorization'] = "Bearer #{fresh_access_token}"
        req.headers['Content-Type'] = 'application/json'
      end

      # HTTP status → canonical provider error: the mapped_error pattern of the
      # SDK-backed providers, applied to raw REST statuses. 401/403 auth, 429
      # rate limit, anything else a generic (but diagnostic) Provider::Error.
      def raise_mapped_http_error(status, body)
        message = "Vertex AI HTTP #{status}: #{error_message_from(body)}"
        case status
        when 401, 403 then raise AuthError, message
        when 429      then raise RateLimitError, message
        else               raise Error, message
        end
      end

      def error_message_from(body)
        parsed = JSON.parse(body.to_s)
        parsed.dig('error', 'message') || body.to_s[0, 300]
      rescue JSON::ParserError
        body.to_s[0, 300]
      end

      # ---- request translation (canonical → Gemini) ------------------------

      def build_generate_payload(messages:, tools:, model:, max_tokens:, temperature:, provider_options: {})
        system_prompt, conversation = split_system(messages)
        # provider_options are Gemini generationConfig extras (topP, topK,
        # stopSequences, …) — merged LAST so a raw override wins, the same
        # contract as the other providers' param merge.
        generation_config = answer_budget_config(model, max_tokens).merge(temperature: temperature)
                                                                   .merge(provider_options.to_h.symbolize_keys)
        payload = {
          contents: translate_messages_for_gemini(conversation),
          generationConfig: generation_config
        }
        payload[:systemInstruction] = { parts: [{ text: system_prompt }] } if system_prompt
        payload[:tools] = [{ functionDeclarations: tools.map { |t| gemini_function_declaration(t) } }] if tools.present?
        payload
      end

      # See THINKING_BUDGET: a thinking family gets the budget and the reserve,
      # every other model the bare limit, as before.
      def answer_budget_config(model, max_tokens)
        return { maxOutputTokens: max_tokens } unless THINKING_MODEL_PATTERN.match?(model.to_s)

        { maxOutputTokens: max_tokens + THINKING_BUDGET, thinkingConfig: { thinkingBudget: THINKING_BUDGET } }
      end

      # A tool without arguments goes out without parameters. Gemini's schema subset refuses an
      # OBJECT with empty properties, and every tool schema goes with every answer: one tool
      # without arguments (help_contents) would fail every request on this provider.
      def gemini_function_declaration(tool)
        declaration = { name: tool[:name], description: tool[:description] }
        schema = tool[:input_schema]
        properties = schema.is_a?(Hash) ? schema[:properties] || schema['properties'] : nil
        declaration[:parameters] = schema if properties.present?
        declaration
      end

      # Translates the provider-neutral canonical message form into Gemini's
      # wire shape (contents: role user|model, parts: text / functionCall /
      # functionResponse — function results ride in a role:"user" turn).
      #
      # Enforces the SAME strict bundling contract as
      # AnthropicProvider#translate_messages_for_anthropic: tool results MUST
      # directly follow the assistant turn that requested them. Orphan tool
      # messages and split bundles (assistant-with-tool_calls → tool →
      # non-tool → tool) fail fast here instead of surfacing as an opaque
      # Vertex 400.
      #
      # Gemini has NO tool_call ids — functionCall/functionResponse pair up by
      # function NAME and order. Outbound we synthesise deterministic ids from
      # name + part index (#canonical_tool_call); inbound we resolve a tool
      # message's tool_call_id back to the function name via the id→name map
      # collected from the preceding assistant turns of the same conversation.
      def translate_messages_for_gemini(conversation)
        contents = []
        pending_tool_parts = []
        expecting_tool_results = false
        tool_call_names = {} # synthesised id → function name

        conversation.each_with_index do |msg, idx|
          if msg[:role].to_s == 'tool'
            unless expecting_tool_results
              raise Provider::Error,
                    "Gemini translator: orphan/split tool_result at index #{idx} " \
                    '(no preceding assistant-with-tool_calls, or batch already consumed)'
            end
            pending_tool_parts << gemini_function_response_part(msg, tool_call_names)
            next
          end

          unless pending_tool_parts.empty?
            contents << { role: 'user', parts: pending_tool_parts }
            pending_tool_parts = []
          end

          # Any non-tool message resets the expectation — a later tool-role
          # message would be an orphan (caught above), closing the
          # split-bundle pattern exactly like the Anthropic translator.
          expecting_tool_results = false

          contents << translate_non_tool_message(msg, tool_call_names)

          expecting_tool_results = true if assistant_with_tool_calls?(msg)
        end

        contents << { role: 'user', parts: pending_tool_parts } unless pending_tool_parts.empty?

        contents
      end

      def translate_non_tool_message(msg, tool_call_names)
        unless assistant_with_tool_calls?(msg)
          role = msg[:role].to_s == 'assistant' ? 'model' : 'user'
          return { role: role, parts: [{ text: coerce_to_text(msg[:content]) }] }
        end

        parts = []
        parts << { text: coerce_to_text(msg[:content]) } if msg[:content].present?
        msg[:tool_calls].each do |tc|
          tool_call_names[tc[:id].to_s] = tc[:name].to_s
          parts << { functionCall: { name: tc[:name], args: tc[:args] || {} } }
        end
        { role: 'model', parts: parts }
      end

      def gemini_function_response_part(msg, tool_call_names)
        id = msg[:tool_call_id].to_s
        name = tool_call_names[id]
        if name.blank?
          raise Provider::Error,
                "Gemini translator: tool message with unknown tool_call_id #{id.inspect} " \
                '(no matching functionCall in a preceding assistant turn)'
        end

        { functionResponse: { name: name, response: gemini_response_object(msg) } }
      end

      # functionResponse.response must be a JSON OBJECT. Google's documented
      # convention: 'output' carries the result, 'error' an error description
      # the model can reason about (parity with Anthropic's is_error flag).
      def gemini_response_object(msg)
        content = msg[:content]
        return content if content.is_a?(Hash) && !msg[:is_error]

        { (msg[:is_error] ? 'error' : 'output') => coerce_to_text(content) }
      end

      # ---- response translation (Gemini → canonical) ------------------------

      def extract_parts(candidate)
        text_parts = []
        tool_calls = []
        Array(candidate.dig('content', 'parts')).each_with_index do |part, idx|
          # thought parts (thinking-enabled models) are reasoning summaries,
          # not answer content — never leak them into the transcript.
          next if part['thought']

          if part.key?('text')
            text_parts << part['text'].to_s
          elsif part.key?('functionCall')
            tool_calls << canonical_tool_call(part['functionCall'], idx)
          else
            log_unknown_part(part)
          end
        end
        [text_parts, tool_calls]
      end

      # Gemini functionCall parts carry NO id (unlike OpenAI/Anthropic), but
      # the Runner contract requires one — synthesise a deterministic id from
      # the function name + part index. The name embedded in the id is what
      # lets the translator map a tool result back to its function; the index
      # keeps parallel calls of the SAME function distinct within a turn.
      def canonical_tool_call(function_call, index)
        name = function_call['name'].to_s
        raise Error, "Vertex AI returned malformed functionCall (name=#{function_call['name'].inspect})" if name.empty?

        args = function_call['args']
        { id: "#{name}-#{index}", name: name, args: args.is_a?(Hash) ? args : {} }
      end

      def log_unknown_part(part)
        Rails.logger.debug do
          "Lalabase::Llm::GoogleVertexProvider: dropping unknown content part keys=#{part.keys.inspect}"
        end
      end

      # Gemini reports finishReason STOP even when the model wants tools run —
      # the presence of functionCall parts IS the tool-use signal. Derive the
      # canonical 'tool_calls' so the Runner sees one dialect (parity with
      # OpenAI finish_reason=tool_calls / Anthropic stop_reason=tool_use).
      def extract_stop_reason(candidate, tool_calls)
        return 'tool_calls' if tool_calls.any?

        normalise_stop_reason(candidate['finishReason'])
      end

      def extract_text_delta(event)
        Array(event.dig('candidates', 0, 'content', 'parts'))
          .filter_map { |part| part['text'] unless part['thought'] }
          .join
      end

      # ---- SSE parsing ------------------------------------------------------

      # Incremental SSE parsing: chunk boundaries can split events arbitrarily,
      # so we buffer and only consume events terminated by a blank line. Yields
      # the parsed JSON of each `data:` payload; comment/keep-alive events are
      # dropped, as the SSE spec allows.
      def drain_sse_events(buffer)
        while (separator = buffer.match(SSE_EVENT_SEPARATOR))
          raw_event = buffer.slice!(0, separator.end(0))
          data = sse_event_data(raw_event)
          yield parse_sse_json(data) unless data.empty?
        end
      end

      # The last event of a stream may arrive without a trailing blank line.
      def flush_sse_tail(buffer)
        data = sse_event_data(buffer)
        yield parse_sse_json(data) unless data.empty?
        buffer.clear
      end

      # Multi-line data fields are rejoined with \n per the SSE spec (Vertex
      # sends one complete JSON document per data line in practice).
      def sse_event_data(raw_event)
        raw_event.each_line.filter_map { |line| line[/\Adata:\s?(.*)/, 1] }.join("\n")
      end

      def parse_sse_json(data)
        JSON.parse(data)
      rescue JSON::ParserError => e
        raise Error, "Vertex AI returned an unparseable SSE event: #{e.message} (#{data[0, 120].inspect})"
      end

      # ---- usage / embedding helpers ---------------------------------------

      def usage_from_metadata(metadata, model:, start_time: nil)
        metadata ||= {}
        duration_ms = start_time ? ((Time.current - start_time) * 1000).round : nil
        Lalabase::Llm::TokenUsage.build(
          input_tokens: metadata['promptTokenCount'].to_i,
          output_tokens: metadata['candidatesTokenCount'].to_i,
          # totalTokenCount can exceed input+output (thinking tokens) — pass it
          # through when reported so metering books what Google bills.
          total_tokens: metadata['totalTokenCount']&.to_i,
          cost_cents: 0, model: model, estimated: false, duration_ms: duration_ms
        )
      end

      def estimated_usage(messages, captured_content, model, start_time)
        input  = (messages.sum { |m| m[:content].to_s.length } / CHARS_PER_TOKEN).round
        output = (captured_content.length / CHARS_PER_TOKEN).round
        duration_ms = ((Time.current - start_time) * 1000).round
        Lalabase::Llm::TokenUsage.build(
          input_tokens: input, output_tokens: output, cost_cents: 0,
          model: model, estimated: true, duration_ms: duration_ms
        )
      end

      # gemini-embedding-001 unit-normalises only its native 3072-dim output;
      # Matryoshka-truncated vectors must be re-normalised client-side (Google
      # docs). No-op for an all-zero vector (guard_dimensions still validates).
      def normalise_vector(values)
        norm = Math.sqrt(values.sum { |v| v * v })
        return values if norm.zero?

        values.map { |v| v / norm }
      end
    end
  end
end
