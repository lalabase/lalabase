# frozen_string_literal: true

require 'openai'

module Lalabase
  module Llm
    # OpenAI-compatible embedding/chat backend reachable at a custom base URL
    # (Azure OpenAI, LiteLLM proxy, a self-hosted model server, Mistral/IONOS, …).
    # The wire format is identical to OpenAI, so this inherits all of OpenAiProvider
    # — INCLUDING #chat / #stream_chat, which route through the overridden #client
    # (so they talk to the configured uri_base) — and only overrides:
    #   - #client                  → injects the configured uri_base
    #   - #default_embedding_model → the configured model (no ada-002 default)
    #   - #default_chat_model      → the configured model (no gpt-4o-mini default)
    #   - .provider_name           → "openai_compatible" routing key (the honest
    #                                DISPLAY name is carried separately via
    #                                Provider#effective_provider_name)
    #
    # The dimension guard that keeps a mismatched vector from reaching pgvector
    # (which would 22000 on INSERT, far from the cause) is INHERITED: since
    # embedding v2 PR 2 it lives on OpenAiProvider#embed_with_usage / #embed_batch
    # (the base embed path), so this provider needs no override — every returned
    # vector is checked against Provider#expected_embedding_dims (configured dim,
    # else the 1536 default). GoogleVertexProvider (not a subclass) enforces the
    # same guard on its own embed path.
    #
    # NOT inherited since embedding v2 PR 5: the `dimensions:` request param — see
    # #send_dimensions? below for why a third-party endpoint must opt IN.
    class OpenAiCompatibleProvider < OpenAiProvider
      # additional_config key that opts an endpoint IN to the `dimensions:` param.
      SEND_DIMENSIONS_KEY = 'send_dimensions'

      def self.provider_name
        ::AiCredential::PROVIDER_OPENAI_COMPATIBLE
      end

      def default_chat_model
        configured_chat_model.presence ||
          raise(Provider::Error, 'openai_compatible provider requires a chat model (none configured)')
      end

      def default_embedding_model
        configured_embedding_model.presence ||
          raise(Provider::Error, 'openai_compatible provider requires an embedding model (none configured)')
      end

      private

      # Default OFF (embedding v2 PR 5, §3.5.1), unlike the OpenAI parent. This
      # provider talks to Mistral, Ollama, vLLM, LiteLLM, Azure … — endpoints that
      # frequently do not know `dimensions:` and answer a 400 to EVERY embed. And the
      # PR-5 target case does not need the param at all: EU models come with their
      # NATIVE dimension (mistral-embed 1024, nomic 768). Whoever does want Matryoshka
      # truncation through a compatible endpoint sets the flag on the credential
      # (feedback_configurable_over_hardcoded). The safety net in both directions
      # stays Provider#guard_dimensions: if the endpoint does not deliver the
      # configured dim natively, a loud DimensionMismatchError follows instead of
      # silently mixed vector spaces.
      #
      # Parsing is STRICTLY boolean, not truthy: additional_config is admin-entered,
      # UNVALIDATED JSON permitted by the admin controller through a wildcard — the
      # exact channel that was already a P1 in review #350. A plain
      # `if config['send_dimensions']` would repeat that mistake in miniature,
      # because "false", "0" and "" are all truthy in Ruby and would send the param
      # against the stated intent. Missing, invalid or non-boolean ⇒ false
      # (fail-closed, like the dims clamp in Lalabase::Llm::Factory).
      def send_dimensions?(model)
        super && send_dimensions_opt_in?
      end

      def send_dimensions_opt_in?
        ActiveModel::Type::Boolean.new.cast(additional_config&.dig(SEND_DIMENSIONS_KEY)) == true
      end

      # uri_base is threaded through Provider#initialize; without it this
      # provider has no endpoint to talk to.
      def client
        @client ||= begin
          base = api_base.presence ||
                 raise(Provider::Error, 'openai_compatible provider requires an api_base (uri_base) — none configured')
          OpenAI::Client.new(
            access_token: api_key,
            uri_base: base,
            organization_id: organisation_id_param.presence
          )
        end
      end
    end
  end
end
