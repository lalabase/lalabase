# frozen_string_literal: true

module Lalabase
  module Llm
    # Raised at the LLM seams (Factory, Organisation#ai_client) when the
    # organisation has not opted in to AI features (GDPR org-level opt-in,
    # audit 2026-07-03 item 1.2). Subclass of Provider::Error so existing
    # broad provider rescues degrade gracefully instead of surfacing a 500.
    class AiDisabledError < Provider::Error; end

    # Raised at the LLM seam (Factory) when an org's monthly credit budget + grace
    # buffer are exhausted for a quota-counted call (S3, plan §4.3). Ordered AFTER
    # AiDisabledError in the fail-closed hierarchy: an AI-off org never reaches the
    # quota check (the opt-in gate raises first). Subclass of Provider::Error so a
    # call site with a broad provider rescue degrades gracefully (search → full
    # text, RAG → context-free) instead of 500-ing — but the chat/summary paths add
    # a SPECIFIC rescue first, so an exhausted quota shows its own explanatory copy.
    class QuotaExceededError < Provider::Error; end
  end
end
