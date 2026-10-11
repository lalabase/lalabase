# frozen_string_literal: true

module Embeddings
  # Background wrapper around OrganisationReindexer. Runs on the :indexing queue
  # (same as the initial ProjectIndexerJob) so a provider switch can be applied
  # asynchronously per organisation.
  class ReindexOrganisationJob < ApplicationJob
    queue_as :indexing

    # ONE reindex per organisation at a time, extra enqueues DISCARDED (P4d).
    #
    # The rule belongs here rather than at each trigger. Three callers must obey it —
    # Actors::SelectAiPackage's trigger, this file's own re-drive from
    # Embeddings::SwitchWatcherJob, and the P4b dialog once the card doors open — and a
    # rule enforced by hand at three sites is a rule that will be broken at one of them.
    # It is also §9's second hard P4b precondition ("dedup at the trigger"), which a
    # double click on an open card would otherwise walk straight into.
    #
    # The cost of getting it wrong is real, not theoretical: two concurrent runs both
    # see the same records missing from the target space and both embed them, against a
    # quota-metered path (P4a+). The reindexer's skip logic is idempotent ACROSS runs,
    # not between two running at the same moment.
    #
    # :discard, not :block — a queued duplicate has nothing left to do by the time it
    # runs, and the watcher will ask again on its next tick anyway.
    #
    # 12 hours is CRASH INSURANCE, not the expected runtime. The semaphore is released
    # when the job finishes or fails (SolidQueue::ClaimedExecution), so it only ever
    # runs to expiry if a worker is killed mid-run. It has to sit above a realistic
    # reindex — hours for an org of any size on Vertex, whose provider embeds one text
    # per request — because an expiry DURING a live run is exactly the double run this
    # prevents. The price of the generous window is a worst case where a hard crash
    # delays the re-drive; a switch that already takes hours can absorb that.
    limits_concurrency to: 1, key: ->(organisation) { organisation },
                       duration: 12.hours, on_conflict: :discard

    def perform(organisation)
      # GDPR opt-in gate: a bulk re-index embeds ALL org content — skip quietly
      # for a disabled org instead of failing on the factory's AiDisabledError.
      unless organisation.ai_enabled?
        Rails.logger.debug { "ReindexOrganisationJob: skipping organisation #{organisation.id} — AI disabled" }
        return
      end

      # metered: true — THIS job IS the customer-triggered path (P4a: enqueued by
      # Actors::SelectAiPackage when a package choice moves the embedding lane).
      # Operator runs never come through here: rake and DefaultModelMigrator call
      # the reindexer directly and pass false.
      Embeddings::OrganisationReindexer.call(organisation: organisation, metered: true)
    rescue Lalabase::Llm::QuotaExceededError => e
      # The LIKELY failure of a customer-triggered switch, and until now the quiet
      # one: the quota gate fires at the provider build (factory.rb), this job
      # declares no retry_on and ApplicationJob's is commented out — so it landed in
      # failed_executions with no line naming the organisation. The rare case (an
      # unresolvable lane) was logged loudly by the actor; the likely one was not.
      #
      # Swallowed rather than retried on purpose: a monthly budget refills next
      # month, not in 30 seconds, and a retry ladder against a hard quota is only a
      # slower way to fail. Resuming it is P4d's job — E6 asks for a PAUSED state
      # with pickup in the following month, not a retry loop.
      Rails.logger.warn("ReindexOrganisationJob: organisation #{organisation.id} — switch paused, " \
                        "AI quota exhausted: #{e.message}")
    end
  end
end
