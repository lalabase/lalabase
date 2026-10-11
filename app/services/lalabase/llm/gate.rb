# frozen_string_literal: true

module Lalabase
  module Llm
    # The quota half of the LLM seam gate. The AI opt-in half lives in
    # Factory#ensure_ai_enabled! and is ALWAYS evaluated first (fail-closed
    # hierarchy: AiDisabledError before QuotaExceededError, plan §4.3 / test 5) —
    # this module only decides the quota question, for a call already past opt-in.
    #
    # Only calls that WOULD be metered are gated. A BYOK org (nil billing
    # credential) or a system credential without included_in_quota is NEVER blocked
    # here — its usage doesn't count against any budget (plan §4.3, tests 6/8). This
    # is also what makes the rollout soft: while no credential is flagged
    # included_in_quota (the S2 default is FALSE), quota_relevant? is always false,
    # so the gate is inert and not even a ledger query runs.
    #
    # STRIPE SEAM (decision 4A, NOT built — scope §11): a later phase inserts the
    # Account credit balance BETWEEN the org grace buffer and this hard block — a
    # positive balance would short-circuit #exhausted? before it returns true.
    module Gate
      module_function

      # Raises QuotaExceededError when the given call is quota-counted AND the
      # monthly budget + grace buffer are exhausted.
      # @param credential [AiCredential, nil] the system credential the call runs
      #   on, resolved ONCE by the Factory seam (P0) — nil (BYOK) makes the gate
      #   inert. Taking the OBJECT instead of a provider name keeps the gate and
      #   the routing in agreement even when several credentials of the same
      #   provider are in service (KI-Pakete, doc/ki_pakete_plan.md §4.1).
      def ensure_within_quota!(organisation, credential:)
        return unless organisation
        return unless credential&.included_in_quota?
        return unless QuotaLedger.for(organisation).hard_exhausted?

        raise QuotaExceededError,
              "AI quota exhausted for organisation #{organisation&.id || '(none)'}"
      end

      # Boolean form for pre-checks WITHOUT a built provider (quota-aware backfill,
      # quiet pre-skip). True only when the call would be metered AND the ledger is
      # hard-exhausted. Name-based resolution is fine here: pre-checks are UX
      # optimisations, not the guarantee — the seam gate above judges the actual
      # credential (see Factory#ensure_ai_enabled! enforcement-model comment).
      def exhausted?(organisation, provider_name, kind: :chat)
        return false unless organisation
        return false unless quota_relevant?(organisation, provider_name, kind)

        QuotaLedger.for(organisation).hard_exhausted?
      end

      # A call is quota-relevant when it bills OUR system credential and that
      # credential is flagged included_in_quota. billing_credential returns nil for
      # BYOK (of the matching kind), so BYOK calls never count.
      def quota_relevant?(organisation, provider_name, kind = :chat)
        credential = CostCalculator.billing_credential(organisation, provider_name, kind: kind)
        credential&.included_in_quota? || false
      end
    end
  end
end
