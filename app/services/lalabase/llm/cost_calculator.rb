# frozen_string_literal: true

require 'bigdecimal'

module Lalabase
  module Llm
    # THE single source of truth for what an LLM call costs. Replaces the two
    # divergent 2024 price tables S2 deletes (OpenAiProvider::INPUT_COST_PER_1K &
    # AiClientWrapper#estimate_*). Pricing is DATA — the per-1M-token price fields
    # on the active system AiCredential — so it is admin-editable, not hardcoded.
    #
    # Billing rule: we only bill usage that runs on OUR system credential. A BYOK
    # org pays its provider directly, so its cost is 0 and — crucially — is never
    # attributed to a system AiCredential (see UsageTracking, which uses
    # .billing_credential for BOTH cost and attribution so they always agree).
    #
    # Returns BigDecimal cents (fractional), matching ai_usages.cost_cents
    # decimal(12,6): a ~0.002-cent call no longer rounds to 0.
    module CostCalculator
      module_function

      # PREDICTS which system credential a call of this kind would bill, or nil
      # when we wouldn't bill it: BYOK (org's own key) or no active system
      # credential for the provider.
      #
      # Since P0 this is a PRE-CHECK resolution only (Gate.quota_relevant? /
      # .exhausted?, callers without a built provider). The metering itself does
      # NOT use it: cost and attribution read Provider#billing_credential — the
      # credential the Factory actually routed to — because with several
      # credentials of the same provider in service (KI-Pakete,
      # doc/ki_pakete_plan.md §4.1) a name-based lookup is ambiguous.
      #
      # `kind` MUST match the call being predicted: chat and embeddings have
      # SEPARATE BYOK columns and route independently (Factory.for_chat vs
      # .for_embeddings), so an org can run BYOK chat on the system embedding
      # credential (or vice versa).
      # @param kind [Symbol] :chat or :embedding
      # @return [AiCredential, nil]
      def billing_credential(organisation, provider_name, kind: :chat)
        return nil if byok?(organisation, provider_name, kind)

        ::AiCredential.active_for_provider(provider_name)
      end

      # @param credential [AiCredential, nil] resolved via .billing_credential (nil = don't bill)
      # @return [BigDecimal] cents
      def chat_cents(credential:, input_tokens:, output_tokens:)
        return BigDecimal(0) if credential.nil?

        per_million(input_tokens, credential.input_cost_per_1m_cents) +
          per_million(output_tokens, credential.output_cost_per_1m_cents)
      end

      # @param credential [AiCredential, nil]
      # @return [BigDecimal] cents
      def embedding_cents(credential:, tokens:)
        return BigDecimal(0) if credential.nil?

        per_million(tokens, credential.embedding_cost_per_1m_cents)
      end

      # BYOK for the given kind: the chat and embedding credentials are checked on
      # their OWN columns (has_own_ai_credentials? = chat, has_own_embedding_credentials?
      # = embeddings), matching how Factory routes each.
      def byok?(organisation, provider_name, kind = :chat)
        predicate = kind == :embedding ? :has_own_embedding_credentials? : :has_own_ai_credentials?
        organisation.respond_to?(predicate) &&
          organisation.public_send(predicate, provider_name)
      end

      # (tokens / 1_000_000) * price_per_1m_cents, as BigDecimal. nil price (not yet
      # configured) or non-positive tokens ⇒ 0, so an un-priced credential degrades
      # to "free" instead of raising — the model-level guard is what forces prices
      # onto quota credentials.
      def per_million(tokens, price_per_1m_cents)
        return BigDecimal(0) if price_per_1m_cents.nil? || tokens.to_i <= 0

        (BigDecimal(tokens.to_i) * BigDecimal(price_per_1m_cents.to_i)) / 1_000_000
      end
    end
  end
end
