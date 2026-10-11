# frozen_string_literal: true

module Lalabase
  module Llm
    # THE single place that writes an AiUsage row for a completed LLM call.
    #
    # Extracted from ChatResponseJob#track_ai_usage so the chat job AND the migrated
    # chat callers (document summaries, ticket summaries, customer descriptions,
    # ask-AI) share ONE tracking path — same BYOK attribution, same costing. Before
    # S2 the job had this logic inline and the five legacy callers got tracking from
    # AiClientWrapper's parallel implementation; consolidating removes that fork.
    # S3 extends THIS one method with credits / per-action metering.
    module UsageTracking
      module_function

      # @param organisation [Organisation]
      # @param provider [Lalabase::Llm::Provider] the routed provider; its effective
      #   #provider_name drives BOTH attribution and costing.
      # @param token_usage [Hash] the provider result's :token_usage
      #   ({input_tokens:, output_tokens:, total_tokens:, estimated:, duration_ms:}).
      # @param call_type [String] short label for the call site (stored in metadata[:method]).
      # @param action [String] the metered action (ActionRegistry key) — drives credits.
      # @param model [String, nil] model actually used (result[:model_used]).
      # @param user [User, nil] who triggered the call (nil for system/background jobs).
      # @param subject [ApplicationRecord, nil] the record the call acted on (chat, ticket, …).
      # @return [AiUsage, nil] nil if tracking failed (never raises — tracking is a
      #   side effect and must not break the user-facing feature).
      def record(organisation:, provider:, token_usage:, call_type:, action:, model: nil, user: nil, subject: nil)
        usage = token_usage || {}
        provider_name = provider.provider_name

        # The credential that SERVED the call, resolved once by the Factory and
        # carried on the provider (P0) — feeds BOTH cost and attribution, so they
        # always agree: a BYOK org's usage costs us nothing (nil credential ⇒ 0)
        # and is never attributed to a system credential (ai_credential: nil).
        # No second name-based lookup: with several credentials of the same
        # provider in service (KI-Pakete), that lookup would bill the wrong one.
        credential = provider.billing_credential
        cost_cents = CostCalculator.chat_cents(
          credential: credential,
          input_tokens: usage[:input_tokens].to_i,
          output_tokens: usage[:output_tokens].to_i
        )

        # Chat actions are flat-credit today (context cap keeps that honest), but pass
        # tokens through anyway: credits_for ignores them for a flat action, and a
        # future token-metered action routed through .record then bills correctly
        # instead of silently costing its base price.
        book(
          organisation: organisation, provider_name: provider_name, credential: credential,
          tokens: usage[:total_tokens] || 0, action: action,
          credits: ActionRegistry.credits_for(action, tokens: usage[:total_tokens].to_i),
          # decimal(12,6) now — no .round, which used to drop ~0.002-cent calls to 0.
          cost_cents: cost_cents, model: model, user: user, subject: subject,
          metadata: {
            method: call_type,
            input_tokens: usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            duration_ms: usage[:duration_ms],
            estimated_tokens: usage[:estimated]
          }
        )
      rescue StandardError => e
        Rails.logger.error "Lalabase::Llm::UsageTracking: failed to record usage: #{e.message}"
        nil
      end

      # Embedding metering (S3, decision 1A): ONE row per run/search. total_tokens
      # comes from the provider's usage; credits are token-metered via the registry
      # (document_indexing = per started 1k tokens; semantic_search = flat). BYOK is
      # logged but not billed (nil credential ⇒ 0 cost, and the gate never counted
      # it either).
      def record_embedding(organisation:, provider:, total_tokens:, action:, model: nil, user: nil,
                           subject: nil, call_type: 'embedding', fragment_count: nil)
        provider_name = provider.provider_name
        # The credential of the space that served this call, carried on the
        # provider by Factory.for_embeddings / .for_embedding_space (P0). This is
        # the SPACE's credential, not a fresh lookup off the org's CURRENT
        # embedding columns — during a staged switch the two can differ, and the
        # bill must follow the call.
        credential = provider.billing_credential
        tokens = total_tokens.to_i
        book(
          organisation: organisation, provider_name: provider_name, credential: credential,
          tokens: tokens, action: action,
          credits: ActionRegistry.credits_for(action, tokens: tokens),
          cost_cents: CostCalculator.embedding_cents(credential: credential, tokens: tokens),
          model: model, user: user, subject: subject,
          metadata: { method: call_type, fragment_count: fragment_count }.compact
        )
      rescue StandardError => e
        Rails.logger.error "Lalabase::Llm::UsageTracking: failed to record embedding usage: #{e.message}"
        nil
      end

      # Shared writer for ONE AiUsage row. AiUsage.provider stays the ROUTING KEY
      # (openai / openai_compatible / …) so the admin per-provider aggregation keeps
      # matching; the EFFECTIVE display name (e.g. "Mistral EU") goes into metadata
      # for provenance instead.
      def book(organisation:, provider_name:, credential:, tokens:, action:, credits:, cost_cents:,
               model:, user:, subject:, metadata:)
        AiUsage.track_usage(
          organisation, provider_name, tokens,
          ai_credential: credential, user: user, subject: subject,
          action: action, credits_used: credits, model: model, cost_cents: cost_cents,
          metadata: metadata.merge(effective_provider: credential&.display_name.presence).compact
        )
      end
    end
  end
end
