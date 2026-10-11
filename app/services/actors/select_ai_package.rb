# frozen_string_literal: true

# app/services/actors/select_ai_package.rb
#
# The organisation picks (or drops) a curated AI package — KI-Pakete P2,
# doc/ki_pakete_plan.md §6.1/§7. One row, four columns, and the whole weight of
# the actor is in what it REFUSES.
#
# Two things are written together on purpose: the choice (ai_package_id +
# ai_package_tier_key) and the protocol of who chose it when
# (ai_package_selected_at/_by, §7) — "EU is the default, US the deliberate
# deviation" is only auditable if the deviation carries a name and a timestamp.
#
# Since KI-Pakete P4a (doc/ki_pakete_p4_plan.md §4) the actor also STARTS the
# search-side migration when the choice moves the embedding lane: the refusal
# :embedding_switch_blocked is gone and #enqueue_jobs builds the target space and
# queues the reindex instead. What it deliberately does NOT do is flip the read
# lane — the old space keeps serving search until the new one is complete.
#
# Domain failures use precise codes: :package_not_found / :package_not_published /
# :package_not_curated / :unknown_tier / :tier_not_offered /
# :tier_credential_unusable.

module Actors
  class SelectAiPackage < BaseActor
    # The messages are errors ON organisations.ai_package — the scope Rails would
    # use for a model validation of the same content, and the surface renders them
    # exactly like one.
    ERROR_SCOPE = 'activerecord.errors.models.organisation.attributes.ai_package'

    # @param organisation [Organisation] whose package choice changes
    # @param params [Hash, ActionController::Parameters] :ai_package_id (blank =
    #   back to "Eigene Konfiguration"), :ai_package_tier_key (blank = the
    #   default rung)
    # @param current_user [User] REQUIRED since P4e, and no longer only for the
    #   ai_package_selected_by stamp: #log_choice writes an Activity, whose `actor`
    #   is a mandatory belongs_to (activity.rb:48, actor_id NOT NULL). With nil the
    #   whole write fails as :validation_failed and rolls back — a console or rake
    #   caller would otherwise get an error about a field it never mentioned. The one
    #   production caller (ai_settings_controller#select_package) is behind
    #   BaseController#set_organisation, which redirects without a user.
    def initialize(organisation:, params:, current_user:)
      super()
      @organisation = organisation
      @params = params || {}
      @current_user = current_user
    end

    def record
      @organisation
    end

    # The input is judged first and the consequence second: an org that sent a
    # rung the package does not offer should hear about the rung, not about a
    # reindex it never asked for.
    def perform
      # FIRST, and inside BaseActor's transaction: every judgement below reads
      # @organisation.ai_package_id, and the controller loaded that object before
      # this actor ran. Without the row lock two admins racing produce a real
      # lost update — B moves the org to package Q, A's stale object still says P,
      # #rung_change_only? answers true on A's request, the lane question is
      # skipped and Q is overwritten with P. Since P4a the consequence is worse
      # than the refusal it used to bypass: the org routes into P's lane with NO
      # reindex started, so its search reads a space nothing writes to — silently
      # empty results rather than a visible rejection.
      #
      # `organisations` carries no lock_version, so optimistic locking is not
      # available here; #lock! reloads under FOR UPDATE, which is what makes the
      # comparison below speak about the row this transaction will write.
      @organisation.lock!
      package = resolve_package
      tier_key = resolve_tier_key(package)
      # A pure rung change cannot move the embedding lane — §2 is exactly that
      # statement ("the embedding model hangs on axis 1 and NEVER on axis 2"), and
      # the ladder has no embedding slot to move it with. Asking anyway would not
      # merely be redundant: #embedding_switch? fails CLOSED, answering true
      # whenever the triple is not RESOLVABLE (a disabled embedding credential,
      # say). Under P2 that took a customer's cost decision hostage to a fault in
      # the search half; under P4a it would spend their quota on a full reindex
      # that changes nothing. Same short-circuit, and it got MORE load-bearing.
      #
      # Asked BEFORE the write and remembered, because it is a question about the
      # DIFFERENCE: afterwards the org already routes through the new package and
      # every comparison answers "no switch". #enqueue_jobs runs after the
      # transaction and reads the answer, not the state.
      @embedding_lane_moves = !rung_change_only?(package) && embedding_switch?(package)
      # Read BEFORE the write for the same reason: the protocol entry below states a
      # DIFFERENCE, and afterwards the org already IS the new state.
      previous_package = previous_package_for(package)
      previous_tier_key = @organisation.ai_package_tier_key
      # The protocol is stamped for a rung change too: same columns, same
      # responsibility trail. Who moved this org onto the expensive rung is as
      # much an operating fact as who chose the jurisdiction (§7).
      @organisation.update!(ai_package: package, ai_package_tier_key: tier_key,
                            ai_package_selected_at: Time.current,
                            ai_package_selected_by: @current_user)
      log_choice(previous_package: previous_package, previous_tier_key: previous_tier_key,
                 package: package, tier_key: tier_key)
    end

    # P4a: where the refusal used to be. The switch that P2 turned away is now
    # STARTED here — build the target space for the new triple, then re-embed the
    # corpus into it. The flip to that space is neither done nor awaited here: the
    # read lane keeps serving the OLD space until the target is complete (P4d's
    # watcher decides that), which is what makes the switch seamless for search.
    #
    # After commit, both of them, per the actor contract — and the reason is
    # sharper than the convention: EnsureSpace resolves the CONFIGURED triple,
    # which is only the new package's triple once this transaction's write is
    # visible.
    def enqueue_jobs
      return unless @embedding_lane_moves
      # Falle 4 (plan §5), and it is load-bearing rather than tidy: with the opt-in
      # off, Factory raises AiDisabledError — which #embedding_switch? rescues to
      # `true` (fail closed) while EnsureSpace would simply raise it, after the
      # commit, where nothing maps it to a Result. An org without the opt-in has no
      # corpus to re-embed either, so there is nothing to start.
      return unless @organisation.ai_enabled?

      # The rescue sits INSIDE the block because that block runs after the commit,
      # and that is what decides the error policy: the customer's write has already
      # happened and is correct. If the new lane cannot be resolved — the org's own
      # credential AND the package's disabled, an operator fault — then raising
      # would travel back through BaseActor's error mapping and hand the caller a
      # failure Result for a change that DID take place. So it is logged, loudly
      # and with the org id, and the write stands.
      #
      # ⚠️ INPUT FOR P4d: this leaves an org whose lane moved but whose target
      # space was never created. A watcher that scans existing embedding_spaces
      # rows will not see it — the candidate set has to start from the
      # ORGANISATION (configured != active), or this org waits forever.
      enqueue_after_commit do
        ::Embeddings::EnsureSpace.call(organisation: @organisation)
        ::Embeddings::ReindexOrganisationJob.perform_later(@organisation)
      rescue ::Lalabase::Llm::Provider::Error => e
        Rails.logger.error("[#{self.class}] could not start the embedding migration for " \
                           "organisation #{@organisation.id}: #{e.class}: #{e.message}")
      end
    end

    private

    # The HISTORY §7 asks for, next to the "last choice" the four columns hold
    # (KI-Pakete P4e, doc/ki_pakete_p4_plan.md E4). "EU ist Standard, US die
    # bewusste Abweichung" is only auditable if every deviation left a trace with a
    # name, a time and — the point of the whole chapter — the JURISDICTION it moved
    # between. `ai_package_selected_at/_by` overwrite each other; this does not.
    #
    # ⚠️ An Activity is NOT a quiet audit row. `after_create_commit` fires
    # OutboxEvent.create_from_activity!, which reaches
    # Notifications::FanoutService through OutboxConsumeJob
    # (docs/architektur/seiteneffekt_ketten.md). This key matches no convention in
    # #auto_derive_event_type, and #derive_event_type never returns nil — it falls
    # back to SYSTEM_MESSAGE. Left alone, one package switch would fan a generic
    # system notification (and its e-mails) across the org through the score-based
    # non-ticket path.
    #
    # Hence skip_notifications. Nobody is told, on purpose: the switch is synchronous,
    # behind a confirmation dialog, so the one person who would be notified is the
    # one who just clicked. Notifying OTHER admins is a product decision and does
    # not belong in a slice that was meant to write a log line — if it is ever
    # wanted, the fanout path for a non-ticket trackable has to be measured first.
    #
    # (`skip_notifications` exists twice: this attr_accessor gates the OutboxEvent,
    # and OutboxEvent#should_create_notifications? separately reads
    # parameters['skip_notifications']. The attr is the effective gate here; the
    # second is not set, so the payload below stays a payload.)
    #
    # Raises like any other write in this transaction — a change without its
    # protocol entry is the exact state §7 forbids, so it must not commit alone.
    def log_choice(previous_package:, previous_tier_key:, package:, tier_key:)
      package_changed = previous_package&.id != package&.id
      # A write that moved neither axis is reachable only by hand-built POST (every
      # door renders the current package as a disabled state). Logging it would put
      # "nothing happened" into the audit trail.
      return if !package_changed && previous_tier_key == tier_key
      # No package on EITHER side, so there is no package choice to protocol — only a
      # leftover rung key being cleared. A Leistungsstufe is meaningful only inside a
      # package: without one, `ai_tier_selected` would render `von "thorough" auf ""`,
      # the empty pair of quotes #package_label avoids one axis over (P4e review I3).
      # Reachable only through data drift (a rung key surviving on an org with no
      # package), and the honest answer there is silence rather than an invented rung.
      return if package.nil? && previous_package.nil?

      # ⚠️ with_tenant, not just `organisation:`. acts_as_tenant OVERWRITES the passed
      # organisation from ActsAsTenant.current_tenant in a before_validation on
      # :create — so under a foreign tenant this row lands in the WRONG mandant
      # (measured, P4e review M6), and under no tenant it raises NoTenantSet, which
      # is a fault this actor did not have before P4e (it touched no tenant-scoped
      # model). The controller happens to set both to the same org, so neither is
      # reachable through the customer door — but an audit row whose correctness
      # depends on the caller's ambient state is not an audit row.
      # SwitchWatcherJob#advance takes the same precaution against the same trap.
      ActsAsTenant.with_tenant(@organisation) do
        Activity.create!(
          organisation: @organisation,
          actor: @current_user,
          trackable: @organisation,
          # The two axes of §2 get two verbs, because only ONE of them carries legal
          # weight — an audit that called a rung change a jurisdiction decision would
          # be worse than no audit.
          action: package_changed ? AiProtocolActions::PACKAGE_SELECTED : AiProtocolActions::TIER_SELECTED,
          secondary: package,
          parameters: choice_parameters(previous_package, package, previous_tier_key, tier_key),
          skip_notifications: true
        )
      end
    end

    # Two fields per side, each with a job. The LABEL is what a human reads in the
    # trail and is interpolated straight into activities.messages.* — so it must
    # never be blank, which is why "no package" resolves to the same wording the
    # catalogue uses rather than to an empty pair of quotes. The ID is what survives
    # a package being renamed or withdrawn.
    #
    # The jurisdiction is stored RAW (`eu_native`, …), not as a label: it is the
    # legally interesting field, and an audit row that froze today's German wording
    # would be worth less in two years than the key the matrix still understands. It
    # comes from AiPackage#effective_jurisdiction — the same derivation the card and
    # the Art. 13 notice show, so the log cannot record a rung the customer never saw.
    def choice_parameters(previous_package, package, previous_tier_key, tier_key)
      {
        'from_package_id' => previous_package&.id,
        'from_package' => package_label(previous_package),
        'from_jurisdiction' => previous_package&.effective_jurisdiction,
        'to_package_id' => package&.id,
        'to_package' => package_label(package),
        'to_jurisdiction' => package&.effective_jurisdiction,
        # Blank and DEFAULT_KEY mean the same rung (see #resolve_tier_key), so the
        # trail states the rung rather than reproducing the difference between two
        # ways of writing it.
        'from_tier_key' => previous_tier_key.presence || ::AiPackageTier::DEFAULT_KEY,
        'to_tier_key' => tier_key,
        # Whether this choice also triggered a paid re-embedding — the operating
        # half of the same decision, and the only field here that cannot be
        # reconstructed from the two package rows afterwards.
        'embedding_lane_moved' => @embedding_lane_moves
      }
    end

    # ⚠️ `locale: I18n.default_locale`, not the request's. The comment above insists the
    # jurisdiction is stored raw so no audit row freezes today's German wording — and
    # this line freezes a translation, which is the same mistake one field over (P4e
    # review M2). Measured: a switch performed under an English UI wrote "Own
    # configuration" into a trail a German admin reads.
    #
    # Pinning the locale is the proportionate fix rather than resolving the label at
    # render time. The label MUST be interpolatable and never blank — Activity#message
    # substitutes it straight into activities.messages.*, and YAML cannot branch on
    # "no package" — while the machine-readable truth is `to_package_id: nil`, which is
    # locale-independent and is what a query filters on. Pinning at least makes every
    # row say the same thing regardless of who clicked.
    def package_label(package)
      package&.name ||
        I18n.t('views.organisations.ai_settings.packages.custom.title', locale: I18n.default_locale)
    end

    # The package the org is on RIGHT NOW, loaded the way #choice_parameters needs it.
    #
    # Not `@organisation.ai_package`: AiPackage#effective_jurisdiction derives the rung
    # from #referenced_credentials, which walks the embedding slot AND every rung's chat
    # credential. On a lazily loaded row that is one query per credential — Prosopite
    # fails the actor's own specs on it, which is the cheap version of finding out.
    #
    # A rung change reuses the very object it is switching within, rather than loading
    # the same row twice: both sides of the trail then also derive their jurisdiction
    # from one set of credentials, so they cannot disagree about a package that did not
    # move.
    def previous_package_for(package)
      id = @organisation.ai_package_id
      return nil if id.blank?
      return package if package&.id == id

      packages_with_credentials.find_by(id: id)
    end

    def packages_with_credentials
      AiPackage.includes(:embedding_credential, tiers: :chat_credential)
    end

    # Is this write a pure LEISTUNGSSTUFE change — the org's own package, only the
    # rung moves? Deliberately false for a no-op deselection (no package before,
    # none after): that path keeps judging the triple exactly as it did in P2, so
    # an org without a package routes byte-identically to before.
    #
    # ONE caller left, the embedding lane question — reading ai_package_id, which
    # is only a fact about this request once #perform has taken the row lock. Any
    # future caller inherits that precondition.
    def rung_change_only?(package)
      package.present? && @organisation.ai_package_id == package.id
    end

    # @return [AiPackage, nil] nil = deselection, back to the org's own settings
    def resolve_package
      id = param(:ai_package_id)
      return nil if id.blank?

      # Preloaded, because three later readers walk these associations on the same
      # object: #resolve_tier_key (tier_for + chat_credential), #embedding_switch?
      # (the embedding slot) and, since P4e, #choice_parameters via
      # AiPackage#effective_jurisdiction — which reads BOTH. Lazily loaded that is one
      # query per credential.
      package = packages_with_credentials.find_by(id: id)
      reject!(:package_not_found) if package.nil?
      # Both refusals are about the CATALOGUE, not about the data: `active` is
      # the operator's "visible to customers" switch (§7b.1), and a `custom` row
      # is the placeholder for having no package at all — choosing it explicitly
      # would give two different states the same meaning. Dropping the package is
      # the way back, and it has its own path above.
      reject!(:package_not_curated) unless package.curated?
      # `active` is asked of EVERY write, rung change included.
      #
      # P3 briefly exempted a pure rung change here, to spare a customer whose
      # package an operator withdrew from being frozen on an expensive rung. The
      # exemption bought that customer nothing: the switcher renders only from the
      # published, filtered catalogue (ai_settings_controller#load_package_catalogue),
      # so the withdrawn package has no card and no switcher — the permission was
      # reachable by hand-built POST alone. What it did buy was a hole:
      # #published_package_must_carry_the_full_ladder validates `if curated? &&
      # active?`, so an UNPUBLISHED package may legitimately lose a rung, and
      # writes onto exactly that package were the ones the exemption let through
      # (Factory#curated_tier and AiPackage#utility_tier then degrade silently, by
      # design — their fallbacks are cost decisions, but they assume a full ladder).
      #
      # Unfreezing that customer is a UI job, not an Actor permission: render the
      # current package's card outside the filters (P4, together with the guided
      # switch that is the real way out).
      reject!(:package_not_published) unless package.active?

      package
    end

    # Blank means the default rung — the state every org starts in, and the one
    # the P2 card still posts when it only selects a package. A deselection
    # carries no ladder at all, so the column goes back to NULL rather than
    # keeping a rung that no longer refers to anything.
    def resolve_tier_key(package)
      return nil if package.nil?

      key = param(:ai_package_tier_key).presence || ::AiPackageTier::DEFAULT_KEY
      reject!(:unknown_tier, key: key) unless ::AiPackageTier::KEYS.include?(key)
      # Through the model, not a lookup of its own: the catalogue card judges the
      # blank-key case before offering its button (AiPackage#default_selection_tier),
      # and a second detect here is how the two would drift into a button that
      # only ever produces this refusal.
      tier = package.tier_for(key)
      reject!(:tier_not_offered, key: key) if tier.nil?
      # A rung whose credential can no longer serve chat: the Factory refuses it
      # (curated_chat_resolution asks usable_for?(:chat) — enabled, purpose,
      # endpoint) rather than degrading to the provider default. Without this the
      # org would be moved onto the rung and only find out at the next chat
      # message — a write that succeeds and breaks the feature. The rung
      # validation on AiPackageTier does not cover it, because the credential is
      # edited AFTER the package was saved.
      reject!(:tier_credential_unusable, key: key) unless tier.chat_credential&.usable_for?(:chat)

      key
    end

    # Does this write move the org's effective embedding lane? Until P4a this
    # question WAS the refusal (:embedding_switch_blocked, P2 decision
    # 2026-08-02): the chat half of a package was self-service and the search half
    # was not, because the seamless reindex did not exist yet. It exists now, so
    # the same question routes to #enqueue_jobs instead of to a rejection — the
    # question never changed, only the answer's consequence.
    #
    # Stated as "does the effective lane change", never as "is this a curated
    # package": that one formulation covers picking a package, switching between
    # two, and dropping back to the org's own settings — the way back can move
    # the lane just as much as the way in (Falle 5). It also keeps a switch
    # between two packages that SHARE a lane free of a pointless reindex.
    #
    # Asked through Factory.embedding_switch? — the SAME call the card grid and
    # the "Eigene Konfiguration" card make. Re-deriving the comparison here is
    # what let the two doors drift apart: the custom card offered a deselection
    # this guard then refused, every single time. One helper, three callers.
    #
    # The comparison is over the lane's IDENTITY (triple + credential + endpoint),
    # not over the triple alone — see Factory#embedding_identity_for for why a
    # triple-only guard waves a Mistral→IONOS switch through as a no-op.
    def embedding_switch?(package)
      ::Lalabase::Llm::Factory.embedding_switch?(@organisation, package: package)
    end

    # ActionController::Parameters and a plain symbol-keyed Hash both answer #[],
    # a string-keyed Hash does not — so ask for both rather than making the
    # caller's parameter flavour part of this actor's contract.
    def param(key)
      value = @params[key]
      value.nil? ? @params[key.to_s] : value
    end

    def reject!(code, **interpolations)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.#{code}", **interpolations), code: code)
    end
  end
end
