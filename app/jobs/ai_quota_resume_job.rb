# frozen_string_literal: true

# Resumes embeddings an organisation paused while its AI quota was exhausted
# (decision 5A/D13). Triggered when the org gains a way around the shared quota —
# BYOK credentials or a raised budget — and by the monthly reset catch-up.
#
# Delegates to the EXISTING Embeddings::ActivationBackfill (built for the
# structurally identical AI-opt-in catch-up): it only enqueues records still
# missing an embedding, and EmbeddingReprocessingService is now quota-aware, so a
# still-exhausted org no-ops instead of enqueuing a job storm.
class AiQuotaResumeJob < ApplicationJob
  queue_as :default

  def perform(organisation)
    return unless organisation&.ai_enabled?

    Embeddings::ActivationBackfill.call(organisation)
  end
end
