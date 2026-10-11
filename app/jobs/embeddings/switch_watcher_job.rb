# frozen_string_literal: true

module Embeddings
  # Carries every organisation's staged embedding switch to its end — the step that
  # makes P4a's trigger self-sustaining (KI-Pakete P4d, doc/ki_pakete_p4_plan.md E2).
  #
  # Until now nothing finished what a package choice started: Actors::SelectAiPackage
  # enqueues the build, and Actors::FlipEmbeddingModel had only two callers, both in
  # lib/tasks/embeddings.rake. A customer switch would have run, cost quota, and then
  # sat in `configured != active` forever — search reading from the old space for good.
  #
  # A WATCHER rather than a job chain (E2): the flip is a CONDITION ("the target space
  # is complete"), not a moment. Conditions get asked, not hung off the end of a chain
  # that snaps when a job dies — and dying is the normal case here, since the indexing
  # queue declares no retry.
  #
  # It does BOTH halves of that promise: flip what is ready, and re-drive the build for
  # what is not. A watcher that only ever flipped would wait forever on a dead build
  # while the customer watches a progress hint that never moves.
  #
  # Candidate selection (E2.1): a deliberately over-inclusive SQL prefilter plus an
  # authoritative Ruby check. The prefilter is a HINT, never an answer — over-inclusive
  # costs one discarded check, under-inclusive loses an organisation forever.
  class SwitchWatcherJob < ApplicationJob
    queue_as :default

    # Cost per tick, so it is on the record (review finding 5): a candidate resolves its
    # CONFIGURED lane three times — once in #switch_pending?, then twice more inside
    # EnsureSpace (the triple again, plus embedding_credentials_for). Threading the
    # already-computed triple into EnsureSpace would collapse that, but its signature is
    # shared with the build task and the space backfill, and widening it for one caller
    # buys less than it costs today. Worth revisiting if the fleet grows enough for the
    # O(orgs) credential resolutions E2.1 warns about to actually bite.
    def perform
      Organisation.where(ai_enabled: true).find_each { |organisation| advance(organisation) }
    end

    private

    # One organisation, start to finish. Wrapped in with_tenant because a recurring job
    # runs WITHOUT tenant context (§5 Falle 6) and everything below — the space lookup,
    # the anti-joins, the actor — evaluates acts_as_tenant's default scope.
    #
    # One org's failure is that org's problem, not the fleet's — the isolation is the
    # whole reason this is per-element rather than one big pass.
    #
    # StandardError, deliberately not just Provider::Error (review finding 1). The narrow
    # rescue covered only what switch_pending? throws; EnsureSpace below WRITES a row and
    # can raise RecordInvalid or RecordNotUnique — the latter precisely when it races
    # Actors::SelectAiPackage's own EnsureSpace call on the same triple. Since find_each
    # iterates in stable primary-key order and ApplicationJob declares no retry_on, ONE
    # such org would abort the sweep at the same position on every tick, and every
    # organisation behind it would silently never be reached again.
    #
    # error, not warn: an unresolvable lane is routine (the org is misconfigured), but
    # arriving here through anything else is a bug that must not soften into a skip.
    def advance(organisation)
      ActsAsTenant.with_tenant(organisation) do
        next unless switch_pending?(organisation)

        # ALSO the repair for the org that has a moved lane but NO space row, because
        # EnsureSpace failed after the commit in Actors::SelectAiPackage (E2.1, reason 1).
        # It is find-or-create, so for the normal case this is a refresh, not a write.
        attempt_flip(organisation, Embeddings::EnsureSpace.call(organisation: organisation))
      end
    rescue ::Lalabase::Llm::Provider::Error => e
      Rails.logger.warn("#{self.class}: organisation #{organisation.id} skipped — " \
                        "#{e.class}: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("#{self.class}: organisation #{organisation.id} skipped — " \
                         "#{e.class}: #{e.message}")
    end

    # "Is a staged switch running" — the same question as SpaceAlignment::Result
    # #switch_in_progress?, asked WITHOUT SpaceAlignment.call: that runs four aggregate
    # scans with correlated subqueries and is a diagnosis, not a predicate (§5 Falle 1).
    # Neither side here touches content_embeddings (E1) — `:active` reads the snapshot
    # row, `:configured` resolves credentials in Ruby — which is what makes an O(orgs)
    # sweep affordable on a schedule.
    #
    # Deliberately NOT expressed in SQL (E2.1, reason 2): the configured side is a
    # DERIVED triple. OpenAiProvider answers #default_embedding_model from a constant and
    # ignores the configured model, so a join against ai_packages would compare a
    # DECLARED against a DERIVED side and produce both false hits and missed switches.
    #
    # ⚠️ This is constant FALSE for an org without a resolvable active_embedding_space_id:
    # embedding_space_for falls back to the configured triple when no pointer row resolves
    # (factory.rb:263-276), so both sides become the SAME expression with the same
    # arguments. Such an org would get a HARD switch instead of a staged one, and no flip
    # would ever end it.
    #
    # Addressed at the CAUSE rather than here (plan §11): Embeddings::ActivationBackfill
    # gives every org a pointer at its AI opt-in, and `embeddings:check_alignment` reports
    # any that lack one. Deliberately not repaired in this sweep — asked here, "which
    # space is this org actually on" needs a content_embeddings scan for an org that
    # already holds vectors, the exact cost E1 rules out. At activation the same question
    # has one unambiguous answer and costs nothing.
    def switch_pending?(organisation)
      factory = ::Lalabase::Llm::Factory
      factory.embedding_space_for(organisation, space: :configured) !=
        factory.embedding_space_for(organisation, space: :active)
    end

    # The flip is tried FIRST, and its refusal is what routes the rest — rather than
    # asking for completeness here and flipping if it holds.
    #
    # The load-bearing reason is :retired_target. A retired space HAS a row for every
    # record and is only missing `indexed`; re-driving the build repairs nothing there, so
    # a watcher that read "incomplete" off a count of its own would re-enqueue that org
    # forever. The actor already tells the two states apart — this respects the
    # distinction instead of restating it. Second reason: no gap in which content created
    # between a pre-check and the flip lands outside the target space.
    #
    # It is NOT a saving worth claiming (review finding 4). A pre-check would only be
    # wasted work on the tick where the flip SUCCEEDS; while the build runs — hours for a
    # large org — the actor itself pays for both #incomplete_targets and #retired_target?,
    # so a switching org costs eight full anti-join passes every 15 minutes either way.
    # That is the real recurring price of this design; it is bounded by the build's
    # duration, not by the fleet's size.
    def attempt_flip(organisation, target_space)
      result = ::Actors::FlipEmbeddingModel.call(organisation: organisation,
                                                 target_space: target_space,
                                                 current_user: nil)
      return if result.success?

      case result.code
      when :incomplete_target then resume_build(organisation, target_space, result)
      else
        # :already_active (raced with another flip), :retired_target (needs reactivation,
        # not a build), :organisation_gone, :foreign_space. Nothing to do — the next run
        # asks again, and a genuine data fault belongs in an operator's hands.
        Rails.logger.info("#{self.class}: organisation #{organisation.id} not flipped " \
                          "(#{result.code}): #{result.errors.join(' ')}")
      end
    end

    # Re-drive the build — EXCEPT while the quota is exhausted (E2.2). Skipping silently
    # is the point: the state is PAUSED, not failed. E6 asks for pickup in the following
    # month, and a watcher that re-enqueued regardless would start the same job every
    # tick, fail at the same gate and log the same line. Resumption then needs no trigger
    # of its own — the next tick simply stops skipping once the budget rolls.
    #
    # Gate.exhausted? is the provider-free pre-check: it resolves the billing credential
    # and reads the ledger, without building a provider (which is where the ENFORCING
    # gate fires). The space's embedding_provider is the routing key the ledger is keyed
    # by, the same value UsageTracking books under.
    #
    # No "is one already running?" test here — ReindexOrganisationJob enforces that
    # itself via limits_concurrency. Asking from the outside would mean querying Solid
    # Queue's own tables, and getting it WRONG in a specific way: a crashed job keeps
    # finished_at NULL, so it would read as "still running" forever and this watcher
    # would never heal the very failure it exists for.
    def resume_build(organisation, target_space, result)
      if ::Lalabase::Llm::Gate.exhausted?(organisation, target_space.embedding_provider,
                                          kind: :embedding)
        Rails.logger.info("#{self.class}: organisation #{organisation.id} — switch paused, " \
                          'AI quota exhausted; retrying once the budget resets')
        return
      end

      Rails.logger.info("#{self.class}: organisation #{organisation.id} — resuming the " \
                        "embedding build (#{result.errors.join(' ')})")
      Embeddings::ReindexOrganisationJob.perform_later(organisation)
    end
  end
end
