# frozen_string_literal: true

require 'json'

module Lalabase
  module Llm
    # Provider interface for LLM calls. Concrete implementations (OpenAiProvider,
    # AnthropicProvider, OpenAiCompatibleProvider) wrap their respective vendor SDKs
    # and translate to/from the provider-neutral message format (OpenAI-style: array
    # of {role, content} hashes).
    #
    # Embeddings are supported by OpenAiProvider and OpenAiCompatibleProvider (a
    # custom-base-URL backend: Azure / LiteLLM / self-hosted). Anthropic raises
    # NotSupportedError for #embed (no embedding model).
    class Provider
      class Error < StandardError; end
      class NotSupportedError < Error; end
      class AuthError       < Error; end
      class RateLimitError  < Error; end
      # The provider UNDERSTOOD the request and refused it: an exhausted prepaid
      # balance, a model the key has no access to, a parameter the endpoint rejects.
      # Its own class because the two error properties a caller acts on differ from
      # every other failure here: retrying unchanged cannot help (unlike
      # RateLimitError), and the fix lives in the configured access rather than in the
      # key itself (unlike AuthError).
      #
      # ⚠️ It does NOT assert whose fault it is. A malformed request of OURS reaches the
      # endpoint as the same 400, so user-facing copy may name where to look and must
      # not claim the customer misconfigured anything.
      class RequestRefusedError < Error; end
      # An embedding endpoint returned a vector whose dimension does not match the
      # space's expected dimension — raised by #guard_dimensions (see there).
      class DimensionMismatchError < Error; end

      # Fallback embedding dimension when none is configured on the provider
      # (embedding_dims: nil). Historically the hard "1536-lane" invariant
      # (doc/embedding_provider_abstraction_plan.md); with v2 the dimension is a
      # first-class, configurable part of the vector-space triple
      # (doc/embedding_v2_multidim_plan.md §3.2), and this constant is only the
      # default. #guard_dimensions checks against the CONFIGURED dim when set,
      # otherwise this default — so nil still means 1536, exactly as before.
      DEFAULT_EMBEDDING_DIMS = 1536

      attr_reader :api_key, :organisation_id_param, :organisation, :api_base,
                  :configured_embedding_model, :configured_chat_model,
                  :configured_embedding_dims, :additional_config, :billing_credential

      # @param api_key [String]
      # @param organisation_id_param [String, nil] Optional OpenAI org-id header.
      # @param organisation [Organisation, nil] For usage tracking.
      # @param uri_base [String, nil] Custom base URL for OpenAI-compatible endpoints
      #   (ignored by OpenAiProvider, which always talks to api.openai.com).
      # @param embedding_model [String, nil] Configured embedding model; only read by
      #   providers without a sane built-in default (OpenAiCompatibleProvider).
      # @param chat_model [String, nil] Configured chat model (Factory resolves the
      #   precedence org.preferred_chat_model > credential.default_model). Read by
      #   #default_chat_model; an explicit model: arg to #chat still overrides it.
      # @param provider_name [String, nil] Effective/display provider name for
      #   ATTRIBUTION + provenance (#effective_provider_name), e.g. "Mistral EU".
      #   Distinct from the routing key #provider_name.
      # @param additional_config [Hash, nil] Non-secret routing extras from the
      #   credential's additional_config JSON column (GoogleVertexProvider:
      #   project_id + location). NEVER secrets — the column is plaintext.
      # @param embedding_dims [Integer, nil] Configured embedding dimension of the
      #   vector space (doc/embedding_v2_multidim_plan.md §3.2). nil = unset →
      #   #guard_dimensions falls back to DEFAULT_EMBEDDING_DIMS and providers do
      #   NOT send an explicit dimension request param (byte-identical to pre-v2).
      # @param billing_credential [AiCredential, nil] The system credential this
      #   call actually runs on, resolved ONCE by the Factory (nil = BYOK, the org
      #   pays its provider directly). Quota gate and UsageTracking attribution read
      #   THIS object instead of re-resolving by provider name, so metering can
      #   never land on a different credential than the one that served the call
      #   (KI-Pakete P0, doc/ki_pakete_plan.md §4.1 — with packages, several
      #   credentials of the same provider are in service at once and a name-based
      #   second resolution would be ambiguous).
      # @param operator_endpoint [Boolean] true only when uri_base is the endpoint an
      #   operator put on an AiCredential (Factory#operator_endpoint?). Anything else,
      #   above all an endpoint a customer typed, is judged again for every connection
      #   (PublicEndpointAdapter). Defaults to false, so a construction path that
      #   forgets to say is guarded rather than trusted.
      def initialize(api_key:, organisation_id_param: nil, organisation: nil, uri_base: nil,
                     embedding_model: nil, chat_model: nil, provider_name: nil, additional_config: nil,
                     embedding_dims: nil, billing_credential: nil, operator_endpoint: false)
        @api_key = api_key
        @organisation_id_param = organisation_id_param
        @organisation = organisation
        @api_base = uri_base
        @configured_embedding_model = embedding_model
        @configured_chat_model = chat_model
        @configured_provider_name = provider_name
        @additional_config = additional_config
        @configured_embedding_dims = embedding_dims
        @billing_credential = billing_credential
        @operator_endpoint = operator_endpoint
      end

      def operator_endpoint?
        @operator_endpoint == true
      end

      # Non-streaming chat completion.
      #
      # @param messages [Array<Hash>] Canonical (provider-neutral) message form:
      #   [{role: 'system'|'user'|'assistant'|'tool', content: String, tool_calls: [...]?, tool_call_id: String?}]
      #   Concrete providers translate this into their wire format. A system-only
      #   list is VALID input: dialects that require at least one conversation
      #   turn (Anthropic, Gemini) fold it into a single user turn (#split_system).
      # @param tools [Array<Hash>, nil] Optional tool schemas in provider-neutral form:
      #   [{name:, description:, input_schema: <JSON-Schema hash>}]. nil disables tool-use.
      # @param model [String, nil] Provider-specific model id. Falls back to #default_chat_model.
      # @param max_tokens [Integer]
      # @param temperature [Float]
      # @return [Hash] {content:, tool_calls: nil | Array, stop_reason: String,
      #                 model_used:, token_usage: {...}}.
      #   tool_calls elements: {id: String, name: String, args: Hash}.
      #   stop_reason canonical vocabulary (concrete providers map their dialect):
      #     'stop'          — normal end of response
      #     'length'        — hit max_tokens
      #     'tool_calls'    — model wants the Runner to execute tool calls
      #     'content_filter'— provider-side content filter triggered
      #   Unknown values pass through unchanged so the Runner can log them.
      # @param provider_options [Hash] Provider-specific extras merged into the
      #   vendor request (e.g. presence_penalty, reasoning_effort for OpenAI).
      #   Ignored by providers that don't support the given keys.
      def chat(messages:, tools: nil, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {})
        raise NotImplementedError
      end

      # Streaming chat. Calls block with each text delta as it arrives.
      #
      # @yield [String] text delta
      # @return [Hash] same shape as #chat
      def stream_chat(messages:, model: nil, max_tokens: 1500, temperature: 0.7, provider_options: {}, &on_chunk)
        raise NotImplementedError
      end

      # Embeddings — only supported by providers that have an embedding model
      # (OpenAiProvider, OpenAiCompatibleProvider). Anthropic raises here.
      def embed(text:, model: nil) # rubocop:disable Lint/UnusedMethodArgument
        raise NotSupportedError, "Embeddings not supported by #{self.class.provider_name}"
      end

      # Embeddings WITH token usage — the metering entry point (S3). Returns
      # { embedding: Array<Float>, total_tokens: Integer } so the caller can book
      # credits for the run/search. #embed is the vector-only convenience wrapper
      # over this. Only embedding-capable providers implement it; Anthropic raises.
      def embed_with_usage(text:, model: nil) # rubocop:disable Lint/UnusedMethodArgument
        raise NotSupportedError, "Embeddings not supported by #{self.class.provider_name}"
      end

      # Batch embeddings — concrete providers should override for efficiency.
      # Delegates so #embed_batch_with_usage is the ONE batch call site, exactly
      # as #embed delegates to #embed_with_usage. Any other arrangement lets a
      # provider answer the two differently, and the metered path is then the one
      # nobody exercises.
      def embed_batch(texts:, model: nil)
        embed_batch_with_usage(texts: texts, model: model)[:embeddings]
      end

      # Batch embeddings WITH token usage — the metering twin of #embed_batch
      # (KI-Pakete P4a+, doc/ki_pakete_p4_plan.md E6). Returns
      # { embeddings: Array<Array<Float>>, total_tokens: Integer } so a bulk run
      # can sum tokens across its batches and book ONE AiUsage row at the end.
      #
      # The default is the per-text fallback, and it is not a placeholder: the
      # Vertex :predict endpoint accepts a single instance per call and stays on
      # this path on purpose (GoogleVertexProvider, "the sovereign embedding
      # path"). Summing there is exactly as correct as reading a batch usage
      # block — the bill hangs on the token count, not on how many HTTP calls
      # carried it.
      def embed_batch_with_usage(texts:, model: nil)
        results = texts.map { |t| embed_with_usage(text: t, model: model) }
        { embeddings: results.map { |r| r[:embedding] },
          total_tokens: results.sum { |r| r[:total_tokens].to_i } }
      end

      # Lightweight probe for the settings "test connection" button. MUST NOT spend
      # tokens (it is not usage-tracked). Returns true on a successful round-trip;
      # may raise a mapped AuthError/RateLimitError so the caller can surface why.
      def connectivity_check
        raise NotImplementedError
      end

      # @return [String] the ROUTING key, e.g. "openai", "anthropic",
      #   "openai_compatible". This keys PROVIDER_CLASSES and AiCredential lookup
      #   and must never drift — do NOT overload it with a display name.
      def self.provider_name
        name.demodulize.sub(/Provider\z/, '').underscore
      end

      delegate :provider_name, to: :class

      # Capability declaration: can this provider serve embeddings? Drives the
      # purpose validation in AiCredentialProviderRules (a chat-only provider
      # must not carry purpose embedding/both). Embedding-capable providers
      # override to true (OpenAiProvider, inherited by OpenAiCompatibleProvider).
      def self.supports_embeddings?
        false
      end

      # The name for ATTRIBUTION / provenance / Art. 13 transparency, which may be a
      # configured display name (e.g. "Mistral EU") set by the Factory from the
      # credential. Falls back to the routing key when nothing is configured, so an
      # unconfigured openai_compatible endpoint still stamps "openai_compatible"
      # rather than a misleading "openai".
      def effective_provider_name
        @configured_provider_name.presence || self.class.provider_name
      end

      def default_chat_model
        raise NotImplementedError
      end

      # Subclasses that support embeddings should override this; default raises.
      def default_embedding_model
        raise NotSupportedError, "Embeddings not supported by #{self.class.provider_name}"
      end

      # The dimension this provider's vectors must have: the CONFIGURED
      # embedding_dims when set (doc/embedding_v2_multidim_plan.md §3.2),
      # otherwise DEFAULT_EMBEDDING_DIMS. Single resolver so the guard and any
      # request-parameter passthrough agree on the expectation.
      #
      # PUBLIC since embedding v2 PR 2: the provenance stamp
      # (Lalabase::Indexer::EmbeddingColumns) and later the backfill/delta-reindex
      # read the effective dim from OUTSIDE the provider to build the sidecar
      # triple. instance_double(Provider) only exposes the public interface, so
      # the spec story stays honest (no new stubbing).
      def expected_embedding_dims
        configured_embedding_dims || DEFAULT_EMBEDDING_DIMS
      end

      protected

      # Normalize OpenAI-style messages into (system_prompt, conversation_messages) for
      # providers (like Anthropic) that split system from the message thread.
      #
      # A system-only request IS the request: turn-based APIs (Anthropic messages,
      # Gemini contents) reject a payload with no conversation turn at all, so the
      # joined instruction becomes the single user turn and the system slot stays
      # empty. An entirely empty/blank list is NOT repaired here — there is no
      # intent to carry, and rejecting it is the caller's bug to surface.
      def split_system(messages)
        system_parts, conversation = messages.partition { |m| m[:role].to_s == 'system' }
        system_prompt = system_parts.map { |m| m[:content] }.join("\n\n").presence
        return [nil, [{ role: 'user', content: system_prompt }]] if conversation.empty? && system_prompt

        [system_prompt, conversation]
      end

      # Maps a provider's raw stop/finish reason onto the canonical vocabulary
      # documented on #chat, via the concrete provider's STOP_REASON_MAP. Unknown
      # values pass through unchanged so the Runner can log them. Shared here
      # because only the MAP and how `raw` is read differ between providers — the
      # fetch-with-passthrough itself is identical.
      def normalise_stop_reason(raw)
        self.class::STOP_REASON_MAP.fetch(raw.to_s, raw.to_s)
      end

      # Dimension guard: a vector whose length ≠ #expected_embedding_dims must fail
      # loudly HERE instead of as a pgvector 22000 on INSERT, far from the cause.
      # The expectation is the configured dim when set (so a 1024-space accepts
      # 1024 and rejects 1536), else the default. Called on the base OpenAiProvider
      # embed path (#embed_with_usage / #embed_batch), so EVERY vector that reaches a
      # store is checked — OpenAiCompatibleProvider inherits that path, and
      # GoogleVertexProvider (native 3072, truncated via outputDimensionality) guards
      # its own vectors the same way.
      def guard_dimensions(vector)
        expected = expected_embedding_dims
        dims = vector.respond_to?(:length) ? vector.length : nil
        unless dims == expected
          raise DimensionMismatchError,
                "Embedding endpoint returned #{dims.inspect} dimensions, expected #{expected}"
        end
        vector
      end

      # True for a canonical assistant turn that carries tool calls. tool_calls: []
      # (empty Array) is treated identically to nil — both mean "no tool-calls on
      # this turn"; a canonical caller serialising from JSON can produce either
      # form. Shared by the Anthropic and Gemini message translators.
      def assistant_with_tool_calls?(msg)
        msg[:role].to_s == 'assistant' &&
          msg[:tool_calls].is_a?(Array) &&
          msg[:tool_calls].any?
      end

      # Generic text-serialisation for message translators (tool_result content,
      # assistant text-block wraps). When a caller passes a Hash/Array, JSON-encode
      # so the wire sees structured data instead of Ruby's #inspect output
      # (e.g. "{:rows=>...}").
      def coerce_to_text(content)
        return content if content.is_a?(String)
        return content.to_s if content.nil? || content.is_a?(Numeric) || content.is_a?(Symbol)

        JSON.generate(content)
      rescue JSON::GeneratorError
        content.to_s
      end
    end
  end
end
