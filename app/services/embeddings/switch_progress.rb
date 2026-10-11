# frozen_string_literal: true

# KI-Pakete P4c (doc/ki_pakete_p4_plan.md E1) — what a running package switch is
# doing right now, cheap enough to ask on the customer's AI settings page.
module Embeddings
  # The staged switch as ONE state plus two numbers, for the progress notice in the
  # AI settings (P4c). Deliberately NOT Embeddings::SpaceAlignment: that is a
  # DIAGNOSIS — four aggregate scans with correlated subqueries — and §5 Falle 1 is
  # explicit that putting it on a customer surface is how it becomes the N+1 lesson
  # from #368. This asks the cheap questions instead and only pays for counts in the
  # states that have something to count.
  #
  # Measured cost (P4c review, finding I1 — the first version of this comment
  # undercounted, so these are numbers off a sql.active_record subscriber):
  #
  #   AI off / no pointer / no switch  →  0–2 queries
  #   a switch underway                →  14
  #
  # The 14 are: 1 credential resolution + 1 pointer row + 4 anti-joins + 4 counts +
  # 1 SECOND credential resolution inside #quota_blocked? + 3 for the quota ledger.
  # That second resolution is redundant — #embedding_space_for(:configured) already
  # built the descriptor — but Factory keeps #embedding_descriptor private, and
  # widening its public surface to save one query on a page that runs this ONCE per
  # request is the worse trade. Named here so it stays a known cost, not a surprise.
  # (#load_package_catalogue is the single assignment site and no row partial calls
  # this, so there is no #368-style N+1 behind it.)
  #
  # The state order in #measured mirrors Embeddings::SwitchWatcherJob's decision
  # order: the watcher tries the FLIP first, and Actors::FlipEmbeddingModel decides
  # retired-vs-incomplete before the watcher ever looks at the budget. A page asking
  # in a different order would report a standstill about an org one quarter-hour from
  # flipping, or blame the quota for a space no build can repair.
  #
  # Entry point: call
  class SwitchProgress
    # :none           — nothing to say (no switch, no opt-in, or not answerable; see #call)
    # :building       — the target space is being filled; `remaining` says how much is left
    # :paused         — the build cannot continue: the run is metered and the budget is gone
    # :awaiting_flip  — the target is complete and Embeddings::SwitchWatcherJob will flip it
    # :retired_target — every record HAS a row in the target, they are just de-indexed. No
    #                   build repairs that (P4c review, M1) — it needs reactivation.
    STATES = %i[none building paused awaiting_flip retired_target].freeze

    # @param state [Symbol] one of STATES
    # @param remaining [Integer, nil] source rows with no readable row in the target space
    # @param total [Integer, nil] source rows across the four embedded tables.
    #   Both nil in :none, which never measured — so a consumer cannot mistake "not
    #   asked" for "measured zero".
    Result = Struct.new(:state, :remaining, :total, keyword_init: true) do
      # True for every state that describes a switch actually underway — including the
      # two where nothing is moving. Those need the numbers MOST: a customer looking at
      # a stalled rebuild is exactly who has to be told why it stalled.
      def in_progress?
        %i[building paused awaiting_flip retired_target].include?(state)
      end

      # Clamped: `total` and `remaining` come from two passes, so a deletion between
      # them could otherwise produce a negative count on the screen.
      def completed
        return nil if total.nil?

        [total - remaining.to_i, 0].max
      end

      # @return [Integer, nil] 0..100, and 100 only when nothing is left
      def percent
        return nil if total.nil?
        return 100 if total.zero?

        [(completed * 100 / total), 100].min
      end
    end

    def self.call(organisation:)
      new(organisation: organisation).call
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    # @return [Result]
    def call
      return result(:none) unless @organisation.ai_enabled?

      # WITHOUT a pointer this class is structurally blind, and the honest answer is
      # silence. Factory#embedding_space_for(:active) falls back to the CONFIGURED
      # triple when no pointer row resolves (factory.rb:379-390), so both sides of the
      # predicate below become the same expression and no switch can register as
      # pending either way. This early return is therefore a SHORTCUT, not a branch —
      # deleting it changes no answer, only two queries and this explanation. Keep it.
      #
      # An earlier version reported a state of its own here, and being wrong about it
      # is worth recording (P4c review, blocker 1). The INTENT was right: an org that
      # switched without a pointer reads from the new, empty space immediately and no
      # flip ever ends it. But `active_embedding_space_id.blank?` does not select that
      # population — it selects EVERY pointerless org, and for the vast majority
      # nothing is wrong at all: reads and writes both land on the configured space, so
      # search works perfectly. With the measured production pointer count at zero, the
      # notice would have warned every single organisation about a rebuild that was not
      # running. A detector that IS correct — missing_in_space against the configured
      # space — costs four anti-joins per settings page load for every pointerless org,
      # which is §5 Falle 1 exactly.
      #
      # So the fault is not reported here. It already has an operator surface built for
      # it: SpaceAlignment#pointer_state and the `pointer_note` roster line in
      # `embeddings:check_alignment` (#431). That is the division of labour — the
      # customer page shows what it can answer, the operator check finds what it cannot.
      return result(:none) if @organisation.active_embedding_space_id.blank?

      target = factory.embedding_space_for(@organisation, space: :configured)
      return result(:none) if target == factory.embedding_space_for(@organisation, space: :active)

      measured(target)
    rescue ::Lalabase::Llm::Provider::Error => e
      # An unresolvable configured lane is not a progress statement. Same posture as
      # the P4b dialog's quota block: say nothing rather than guess, and leave the
      # finding to `embeddings:check_alignment`, which is built to report it to an
      # operator. A customer settings page must not 500 over it.
      Rails.logger.warn("#{self.class}: no progress statement for organisation " \
                        "#{@organisation.id} — #{e.class}: #{e.message}")
      result(:none)
    end

    private

    def factory
      ::Lalabase::Llm::Factory
    end

    def measured(target)
      remaining, total = measure(target)
      return result(:awaiting_flip, remaining: remaining, total: total) if remaining.zero?
      return result(:retired_target, remaining: remaining, total: total) if retired?(target)
      return result(:paused, remaining: remaining, total: total) if quota_blocked?

      result(:building, remaining: remaining, total: total)
    end

    # `remaining` goes through OrganisationReindexer.missing_in_space rather than a
    # count of this class's own, which is what makes the bar and the flip agree BY
    # CONSTRUCTION: that method is the single anti-join behind the reindexer's skip
    # logic and Actors::FlipEmbeddingModel's completeness check. A separate derivation
    # here could show "0 verbleibend" on a page whose switch the actor then refuses
    # with :incomplete_target.
    #
    # Two passes rather than one `COUNT(*) FILTER (WHERE <anti-join>)`: the FILTER form
    # would pair the numbers atomically, but it also forces the NOT EXISTS into a
    # per-row subplan, while the plain form lets PostgreSQL plan a hash anti-join over
    # the whole table. The skew a concurrent write can open between the two passes is
    # cosmetic — a percentage a hair off for one render, and Result#completed clamps it
    # — and not worth the plan.
    #
    # Same tenant frame as OrganisationReindexer#call and SwitchEstimate: the four
    # models are tenant-scoped and this runs from a request whose current tenant is
    # the org, but also from specs and jobs where it is not.
    def measure(space)
      ActsAsTenant.with_tenant(@organisation) do
        remaining = OrganisationReindexer.missing_in_space(
          organisation: @organisation, space: space
        ).values.sum
        total = OrganisationReindexer::TARGETS.sum do |target|
          target[:model].constantize.where(organisation_id: @organisation.id).count
        end
        [remaining, total]
      end
    end

    # A target that holds a row for EVERY record and is only missing `indexed`: the
    # space was RETIRED after an earlier flip, not left half built.
    #
    # It has to be told apart from a running build because nothing about it is running.
    # Actors::FlipEmbeddingModel refuses with :retired_target, and
    # SwitchWatcherJob#attempt_flip routes that into its do-nothing branch — on purpose,
    # since a build repairs the wrong thing here (reactivation does). Reported as
    # :building, the customer would watch a number that can never move again (P4c
    # review, M1). Reachable via A → B → A on a corpus that has not grown, if the one
    # reindex from Actors::SelectAiPackage dies mid-run.
    #
    # The SAME question Actors::FlipEmbeddingModel#retired_target? asks, through the
    # same method — a second derivation of "retired" could disagree with the actor
    # about the very state it is describing.
    #
    # The extra anti-join pass is why this sits BEHIND `remaining.zero?` and inside the
    # measured branch: it is paid only while a switch is genuinely underway, which is a
    # bounded window, and the watcher already pays both passes for that org every
    # quarter hour.
    def retired?(space)
      ActsAsTenant.with_tenant(@organisation) do
        OrganisationReindexer.missing_in_space(
          organisation: @organisation, space: space, require_indexed: false
        ).values.sum.zero?
      end
    end

    # Is the build stopped by the monthly budget?
    #
    # Asks the CREDENTIAL, not a provider name — via the one seam that resolves it the
    # way the run itself does (Factory#embedding_billing_credential). The P4b dialog
    # asks the identical question through the identical seam, which is the point: the
    # dialog says "das Kontingent deckt den Wechsel" and this page says "pausiert"
    # about the SAME run, so they must not be two derivations.
    #
    # ⚠️ Embeddings::SwitchWatcherJob#resume_build still asks Gate.exhausted? with a
    # provider NAME, which resolves through AiCredential.active_for_provider and can
    # therefore judge a different row than the run bills (P4d follow-up). Gate's own
    # docstring calls the name-based form a UX pre-check rather than the guarantee —
    # the guarantee is Gate.ensure_within_quota! at the provider build, and that one is
    # credential-based like this. So this page agrees with what actually stops the run.
    def quota_blocked?
      credential = factory.embedding_billing_credential(@organisation)
      return false unless credential&.included_in_quota?

      @organisation.ai_quota_ledger.hard_exhausted?
    end

    def result(state, remaining: nil, total: nil)
      Result.new(state: state, remaining: remaining, total: total)
    end
  end
end
