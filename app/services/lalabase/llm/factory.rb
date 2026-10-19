# frozen_string_literal: true

module Lalabase
  module Llm
    # Picks the right Provider instance for an organisation.
    #
    # ONE resolution path, branching on the org's PACKAGE (KI-Pakete P2, E1-C,
    # doc/ki_pakete_plan.md §6.1):
    #
    #   curated — the package names the credential (BY ID), the tier names the
    #             chat model, and the package names the whole embedding triple.
    #   custom  — the org's own columns, i.e. everything below. `ai_package_id
    #             IS NULL` behaves exactly like a `custom` package, which is why
    #             existing orgs need no data migration.
    #
    # `custom` is deliberately NOT a third branch beside BYOK and system
    # credentials — it SUBSUMES both (§6.1 Detailkonflikt 2). Every entry point
    # asks #curated_package once and hands the answer down; nothing else in this
    # module looks at `kind`.
    #
    # Chat (#for_chat), custom leg:
    #   1. The org's `ai_provider` setting (default "openai")
    #   2. Either the org's own BYOK token (`ai_access_token`) or the system-wide
    #      `AiCredential.active_for_provider(name)`
    #
    # Embeddings (#for_embeddings) route INDEPENDENTLY of chat, off the org's
    # `embedding_provider` BYOK columns (default → system OpenAI). This lets an org
    # send embeddings to its own sovereign, OpenAI-compatible endpoint while chat
    # stays elsewhere. The embedding dimension is a configurable part of the
    # vector-space triple (doc/embedding_v2_multidim_plan.md §3.2); 1536 is only
    # the default — see resolve_embedding_dims.
    module Factory
      class MissingCredentialError < Provider::Error; end

      # Keys come from the provider vocabulary (AiCredential::PROVIDER_*), not from
      # repeated literals: these keys ARE the routing contract that
      # AiCredentialProviderRules, the org columns and every provider_name derive
      # from, so a typo here would silently unregister a provider.
      PROVIDER_CLASSES = {
        ::AiCredential::PROVIDER_OPENAI => OpenAiProvider,
        ::AiCredential::PROVIDER_ANTHROPIC => AnthropicProvider,
        ::AiCredential::PROVIDER_OPENAI_COMPATIBLE => OpenAiCompatibleProvider,
        # Gemini via Vertex AI (service-account auth, regional EU endpoint).
        # Registering here is what makes 'google' selectable/activatable again
        # (AiCredentialProviderRules derives from these keys).
        ::AiCredential::PROVIDER_GOOGLE => GoogleVertexProvider
      }.freeze

      # Answer object of .routing_disclosure — see there.
      # `search_on_package_lane`: nil without a package; with one, whether the
      # SERVING space is the package's own lane — the notice states the
      # package's jurisdiction only while that is true.
      Disclosure = Struct.new(:chat_provider_name, :embedding_provider_name,
                              :chat_provider_label, :embedding_provider_label,
                              :package, :search_on_package_lane, keyword_init: true)

      module_function

      # Returns a Provider configured for the org's preferred chat provider.
      #
      # FEATURELESS, and therefore always the ORG's rung (P3): a caller that does
      # not name a feature cannot be a utility path, because "is this helper
      # work?" is a property of the registry row, not of the call. Utility routing
      # is reachable only through #for_feature — which is the point, since the
      # rung has to be paired with a gate that judges the same one.
      def for_chat(organisation)
        build_chat(organisation, utility: false)
      end

      # The shared chat leg of #for_chat and #for_feature's chat lane.
      #
      # The rung is decided ONCE here and threaded down, never re-derived: with
      # two rungs on different providers, a provider_name taken from one rung and
      # credentials taken from the other would not fail — #resolve_credentials
      # would simply not recognise the tier and fall through to the org's own
      # columns. Wrong provider, no error.
      def build_chat(organisation, utility:)
        # Gate FIRST: reading ai_provider before the gate would turn a nil
        # organisation into a NoMethodError instead of the fail-closed
        # AiDisabledError this seam promises (and specs pin) for every entry.
        ensure_ai_enabled!(organisation)
        build(provider_name: chat_provider_name(organisation, utility: utility),
              organisation: organisation, utility: utility)
      end
      private_class_method :build_chat

      # THE branch point of E1-C, and the only one in this module: which package
      # governs this org's routing. `ai_package_id IS NULL` and `kind: custom`
      # answer the same nil, so "custom" is the ABSENCE of a curated package
      # rather than a case of its own (§6.1).
      # @return [AiPackage, nil] nil = read the org's own columns
      def curated_package(organisation)
        package = organisation.try(:ai_package)
        package if package&.curated?
      end
      private_class_method :curated_package

      # Which rung of the ladder a routing decision runs on. 'fast' is the
      # FALLBACK, not merely the column default: it doubles as the utility rung
      # (§2.1), so an org whose tier_key is blank — every org before P3 shipped
      # the switch — or names a rung this package does not offer gets the
      # cheapest rung rather than no chat at all. The rung is a COST decision;
      # falling back on it cannot break a jurisdiction promise, which is why it
      # may degrade quietly where the credential resolution below may not.
      #
      # `utility: true` IGNORES the org's choice by design (P3, §2.1): helper
      # paths take the cheapest rung whatever the org picked for chat. It is a
      # cost decision on a path where a stronger model buys close to nothing —
      # and it never crosses the package, so the jurisdiction the customer chose
      # still holds.
      #
      # nil when the package carries no rungs at all — a data fault (a published
      # package must carry the full ladder, AiPackage validates it), and it fails
      # loudly one step later as a missing credential.
      def curated_tier(package, organisation, utility: false)
        return nil if package.nil?

        # The utility rung is the PACKAGE's own answer (AiPackage#utility_tier),
        # not a second selection written here: the customer-facing hint names that
        # rung by the same call, and a screen deriving it separately is how it
        # ends up promising a rung the request does not use.
        return package.utility_tier if utility

        rungs = package.tiers
        wanted = organisation.try(:ai_package_tier_key).presence || ::AiPackageTier::DEFAULT_KEY
        rungs.detect { |tier| tier.key == wanted } ||
          rungs.detect { |tier| tier.key == ::AiPackageTier::DEFAULT_KEY }
      end
      private_class_method :curated_tier

      # The ONE chat credential a curated org runs on. Public because
      # Organisation's gate predicates must judge the SAME credential the routing
      # will use: re-deriving "which credential" over there is exactly the
      # gate/route drift doc/ki_provider_reichweite_plan.md §1.2 counts three
      # incidents of, and with two openai_compatible credentials side by side the
      # provider-addressed answer is a DIFFERENT credential, not a stale one.
      # `utility:` must be passed by a gate speaking for a utility feature — the
      # rung is part of "which credential", so a gate that omits it judges a
      # different row than the request will use (FeatureRegistry#chat_failure).
      # @return [AiCredential, nil] nil = custom semantics (no curated package)
      def curated_chat_credential(organisation, utility: false)
        curated_chat_tier(organisation, utility: utility)&.chat_credential
      end

      # The RUNG behind #curated_chat_credential. Public for the same reason the
      # credential is, one level up: a surface that has to NAME the routing —
      # the admin overview names credential, model and rung — would otherwise
      # re-derive "which rung" (wanted key, else DEFAULT_KEY) beside this module,
      # and a rung derived twice is the drift §1.2 counts three incidents of.
      # The model belongs to the rung (AiPackageTier#effective_chat_model), so
      # naming the credential alone cannot answer "which AI does this org use".
      # @return [AiPackageTier, nil] nil = custom semantics (no curated package)
      def curated_chat_tier(organisation, utility: false)
        curated_tier(curated_package(organisation), organisation, utility: utility)
      end

      # The embedding twin. Same reason for being public.
      # @return [AiCredential, nil]
      def curated_embedding_credential(organisation)
        curated_package(organisation)&.embedding_credential
      end

      # The effective chat provider name for an org (default: openai). Public
      # because the chat UI's Art. 13 transparency notice must name the SAME
      # provider this factory will route to — deriving it twice would let the
      # legal notice drift from the actual routing decision. That promise is what
      # makes the package branch mandatory here: a curated org routes where its
      # PACKAGE points, so answering off ai_provider would let the legal notice
      # name a provider the request never reaches.
      #
      # nil for a curated package whose rung names no credential — a data fault.
      # Downstream that reads as "not an implemented provider", i.e. a loud no,
      # instead of the plausible-looking wrong yes the org column would give.
      #
      # `utility:` for the same reason as on #curated_chat_credential: the two
      # rungs of a package may sit on different providers, so "which provider
      # does this org chat with" has a different answer for a helper path.
      def chat_provider_name(organisation, utility: false)
        package = curated_package(organisation)
        return curated_tier(package, organisation, utility: utility)&.chat_credential&.provider if package

        (organisation&.ai_provider.presence || ::AiCredential::PROVIDER_OPENAI).downcase
      end

      # Does this organisation's chat run on ITS OWN access (BYOK) rather than on one
      # the operator provides? Public and here rather than derived at the call site,
      # for the same reason #curated_chat_credential is: a caller that has to name
      # WHOSE access just failed must judge the same branch the request took, and a
      # second derivation beside this module is the gate/route drift
      # doc/ki_provider_reichweite_plan.md §1.2 counts three incidents of.
      #
      # Mirrors #resolve_credentials exactly, including its provider comparison: a
      # curated rung governs only while its credential is on the provider this org
      # chats with, otherwise the two branches below it decide. Own token wins over
      # the system credential there, so it answers true here.
      #
      # @return [Boolean] false for a curated package, and false whenever the request
      #   would fall through to AiCredential.active_for_provider
      def own_chat_access?(organisation, utility: false)
        provider_name = chat_provider_name(organisation, utility: utility)
        tier = curated_tier(curated_package(organisation), organisation, utility: utility)
        return false if tier&.chat_credential&.provider == provider_name

        organisation_has_own?(organisation, provider_name)
      end

      # Everything the Art. 13 transparency notice may state about this org's
      # routing, from ONE resolution (KI-Pakete P5). `package` is nil under
      # custom semantics — including the physical `kind: custom` row — because
      # a custom setup routes off the org columns, and presenting it as a
      # curated jurisdiction claim would be exactly the notice/routing drift
      # the provider-name methods above exist to prevent.
      #
      # The embedding side is the SEARCH's recipient: the same space choice the
      # :semantic_search read path makes (the held active row, else the
      # configured lane) — NOT embedding_provider_name, which always answers
      # the configured lane. During a staged switch (P4a starts it, P4d's
      # watcher flips it) the two differ, and every query input really goes to
      # the space that SERVES; a notice reading the configured lane would name
      # the new provider while the old one still receives the input (P5
      # review, MAJOR 1).
      #
      # While that window is open, `search_on_package_lane` is false and the
      # notice DROPS the package's jurisdiction line instead of claiming
      # "Europäisch" over input that still flows to the old provider (pre-
      # landing review, KRITISCH 1). The chat input reaches exactly two
      # recipients — the chat provider and the serving search space; the
      # configured lane receives the org's CONTENT via reindexing (tickets,
      # notes, …, covered by the privacy policy), but chatposts are not
      # indexed, so it is deliberately not named here.
      #
      # The labels are the customer-readable provider names. On a curated
      # source — a held space row's pinned credential, else the package's
      # embedding slot — they come from #display_label: since P0 the three EU
      # presets all run as provider 'openai_compatible', so the PROVIDER name
      # would tell a Mistral customer "OpenAI-compatible endpoint" (§3.4); the
      # credential is what carries "Mistral (EU)", and it is the same string
      # the package card shows. A custom org without a held space stays on the
      # generic provider display names — prior notice behaviour, unchanged;
      # its resolved SYSTEM credential is operator vocabulary, not a recipient
      # the org chose by name.
      #
      # Chat is resolved WITHOUT `utility:`: the notice sits on the chat page
      # and describes the path the user is about to use, not the helper rung.
      def routing_disclosure(organisation)
        package = curated_package(organisation)
        chat_name = chat_provider_name(organisation)
        provider_name, label_credential, row = search_disclosure_source(organisation, package)

        Disclosure.new(
          chat_provider_name: chat_name,
          embedding_provider_name: provider_name,
          chat_provider_label: disclosure_label(curated_chat_credential(organisation), chat_name),
          embedding_provider_label: disclosure_label(label_credential, provider_name),
          package: package,
          search_on_package_lane: package && search_on_package_lane?(row, package)
        )
      end

      # The search recipient for the disclosure: the held active row when one
      # exists (same space choice as the :active read path), else the
      # configured lane. Returns [provider_name, label_credential, row].
      #
      # Deliberately NOT embedding_descriptor: the notice needs a NAME, not a
      # buildable provider — going through the descriptor would resolve the
      # row a second time and decrypt an API key on every chat page render
      # just to reach a display label (pre-landing review, points 2 + 4). The
      # BYOK check therefore reads the CIPHERTEXT's presence, not the token.
      #
      # Degrades instead of raising: the notice sits on the chat page, and a
      # broken space pin must not take the chat down with the search — name
      # the row's provider, drop the label source. Same breadth as
      # active_space_credential_error, which exists for this fault.
      def search_disclosure_source(organisation, package)
        row = active_space_row(organisation)
        if row
          byok = row.read_attribute_before_type_cast(:access_token).present?
          [row.embedding_provider, byok ? nil : space_credential(row), row]
        else
          [embedding_provider_name(organisation), package&.embedding_credential, nil]
        end
      rescue StandardError
        [row&.embedding_provider || embedding_provider_name(organisation), nil, row]
      end
      private_class_method :search_disclosure_source

      # Is the SERVING space the package's own lane? Compared via the row's
      # credential pin, not the triple: two EU presets can produce an
      # identical triple on different endpoints (see embedding_identity_of),
      # while the pin IS the endpoint-and-company identity the jurisdiction
      # claim rests on — a same-company row with a different model still
      # processes in the same legal space. No row means the configured lane
      # serves, which for a package org is the package lane by definition.
      # A row without a pin fails closed: an unproven identity claims nothing.
      def search_on_package_lane?(row, package)
        return true if row.nil?

        row.ai_credential_id.present? && row.ai_credential_id == package.embedding_credential_id
      end
      private_class_method :search_on_package_lane?

      # Label precedence for the disclosure: resolved credential first (nil off
      # a package, and on a data-fault rung), generic provider display name
      # second, raw provider name last so the notice never renders blank.
      def disclosure_label(credential, provider_name)
        credential&.display_label.presence ||
          ::AiCredential.provider_display_names[provider_name] ||
          provider_name
      end
      private_class_method :disclosure_label

      # The two vector spaces an org has (embedding v2 PR 6a, series plan §5.3):
      #
      #   :configured — where NEW embeddings go (the org's embedding_* columns, else
      #                 the system credential). Every write/build path.
      #   :active     — which space SERVES queries (organisations.active_embedding_space_id
      #                 → embedding_spaces snapshot). Every read path.
      #
      # Separating them is the whole point of the staged switch: a config change alone
      # must NOT move serving, or retrieval breaks for the entire build window (B1).
      SPACES = %i[active configured].freeze

      # Returns the embedding provider for the org in the given space.
      #
      # `space:` is a MANDATORY kwarg with NO default, deliberately. Both conceivable
      # defaults carry a SILENT failure mode — :configured would let a new read path
      # embed queries against the wrong space (B1 itself), :active would let a new
      # write path fill the space it is supposed to be replacing. This lane's faults
      # are silent by nature, so the one loud option wins: a caller that does not say
      # gets an ArgumentError instead of a plausible-looking wrong answer.
      def for_embeddings(organisation, space:)
        ensure_ai_enabled!(organisation)
        descriptor = embedding_descriptor(organisation, space)
        # Quota gate (S3): AFTER the opt-in gate (fail-closed order). Inert unless
        # the resolved embedding credential is included_in_quota; raises
        # QuotaExceededError when the monthly budget + grace buffer are exhausted.
        # Judged on the descriptor's OWN credential (P0): for :active that is the
        # credential of the SERVED space — the one actually about to be billed.
        # A BYOK descriptor carries no credential, so the gate is inert even when
        # the org's CURRENT columns would resolve to a quota credential; gate and
        # routing must judge the same call the same way.
        Gate.ensure_within_quota!(organisation, credential: descriptor.credential)
        build_provider(descriptor, organisation)
      end

      # Feature-keyed routing (doc/ai_feature_registry_plan.md R1): reads the SAME
      # registry row Organisation#ai_available_for? gates on, so removing a pin is one
      # line and there is no second place to forget it (plan §5.2).
      #
      # ADVISORY-FREE by design: this method only routes. It asks no availability
      # question and skips no gate — the lane entry points above still run
      # ensure_ai_enabled! and Gate.ensure_within_quota! themselves, which is what
      # keeps the fail-closed guarantee independent of any UI pre-check (§7.3).
      #
      # @param lane [Symbol, nil] required for a multi-lane feature (repository
      #   indexing builds both) — there is no safe default when the lanes route to
      #   different providers.
      # @param space [Symbol] mandatory on the embedding lane, for the same reason
      #   for_embeddings demands it: both conceivable defaults fail SILENTLY.
      def for_feature(key, organisation, lane: nil, space: nil)
        feature = FeatureRegistry.fetch(key)
        if effective_lane(feature, lane) == :embedding
          raise ArgumentError, "Feature #{key.inspect} needs an embedding space (space: :active | :configured)" if space.nil?

          return for_embeddings(organisation, space: space)
        end

        # Loud on a surplus space: (adversarial review B4) — silently ignoring it
        # would let a caller believe it addressed a vector space while routing
        # chat, the same silent-failure class the space: kwarg exists to prevent.
        raise ArgumentError, "Feature #{key.inspect} routes the chat lane — space: does not apply" unless space.nil?

        # A pin is a CHAT-lane property in v1 — the same rule the registry gates on.
        return build(provider_name: feature.pin, organisation: organisation) if feature.pin

        # …and so is the utility rung (P3). Both come off the SAME registry row,
        # which is what lets the registry refuse the contradictory combination at
        # load time instead of resolving it here (FeatureRegistry#validate_entry!).
        build_chat(organisation, utility: feature.utility?)
      end

      def effective_lane(feature, lane)
        return feature.lanes.first if lane.nil? && !feature.multi_lane?
        raise ArgumentError, "Feature #{feature.key.inspect} spans #{feature.lanes.inspect} — pass lane:" if lane.nil?
        raise ArgumentError, "Feature #{feature.key.inspect} has no #{lane.inspect} lane" unless feature.lanes.include?(lane)

        lane
      end
      private_class_method :effective_lane

      # The org's embedding vector space as the provenance triple
      # {embedding_provider:, embedding_model:, embedding_dims:} — WITHOUT the
      # ai_enabled/quota gates: this feeds a local sidecar READ
      # (Embeddings::NearestNeighbors, embedding v2 PR 4b) — no data egress, no API
      # spend — and that read must keep serving while a quota is exhausted. Both
      # properties are pinned in factory_spec.
      #
      # The two spaces answer from DIFFERENT authorities, and that asymmetry is
      # load-bearing (sheet §0.1):
      #
      #   :configured — the triple is only known AFTER the provider is built, because
      #                 the provider class decides the effective model.
      #   :active     — the SNAPSHOT ROW is the truth. It must not be re-derived through
      #                 the provider: OpenAiProvider and GoogleVertexProvider answer
      #                 #default_embedding_model from a CONSTANT and ignore the
      #                 configured model, so a round-trip through them would silently
      #                 relabel an old space as the current one.
      def embedding_space_for(organisation, space:)
        validate_space!(space)
        row = space == :active ? active_space_row(organisation) : nil
        return row.triple if row

        # No pointer yet (fresh org before its first embed, series plan §5.3) → the
        # effective config IS the active space.
        #
        # A pointer that is SET but does not resolve lands here too — deliberately, since
        # raising on every query would be worse — but it is a DATA FAULT and gets a
        # warn log from #active_space_row so it cannot hide in the legitimate case
        # (review finding R3). A pointer that DOES resolve is always used; nothing here
        # second-guesses it.
        ::Lalabase::Indexer::EmbeddingColumns.from(
          build_provider(configured_descriptor(organisation), organisation)
        )
      end

      # The vector-space triple this org WOULD write into with `package` selected
      # — the question P2's switch guard (Actors::SelectAiPackage) and the
      # customer catalogue (AiPackage#embedding_switch_for?) both hang on.
      #
      # It exists instead of reading the package's three columns directly because
      # both sides of that comparison must come from the SAME derivation:
      # OpenAiProvider and GoogleVertexProvider answer #default_embedding_model
      # from a CONSTANT (see #embedding_space_for), so the triple a package
      # PRODUCES is not always the triple it DECLARES. Comparing a declared
      # triple against a derived one would report a switch where there is none —
      # and this guard's whole job is telling those two apart.
      #
      # Gate-free like #embedding_space_for, and for the same reason: it answers
      # a question ABOUT routing without performing any (no egress, no spend).
      # @param package [AiPackage, nil] nil = the custom reading (E1-C)
      # NOTE: the switch guard no longer reads this — it needs the lane's IDENTITY,
      # not just its triple (#embedding_identity_for). Kept as the standalone
      # provenance question and expressed AS a projection of that identity, so the
      # triple has exactly one derivation rather than a second one drifting beside
      # it. Currently spec-only; P4's guided migration is its intended caller.
      def embedding_triple_for(organisation, package:)
        embedding_identity_for(organisation, package: package)[:triple]
      end

      # The system credential an EMBEDDING run of this org would BILL — nil on BYOK
      # and therefore "not metered".
      #
      # Resolved through #configured_descriptor, i.e. the SAME code the run itself
      # travels, rather than re-deriving the package/BYOK/system branch. That is the
      # whole point of the seam: #437's first quota fix asked
      # Gate.quota_relevant?(org, provider_name), which routes through
      # AiCredential.active_for_provider — the single `active: true` row per provider
      # name. A curated package references an ENABLED row instead
      # (#resolve_embedding_credentials:936-937 takes package.embedding_credential
      # without ever consulting active_for_provider). With two openai_compatible rows
      # side by side — the normal case for the EU packages, §4.1 — those are DIFFERENT
      # rows, so the pre-check judged one credential's included_in_quota flag while the
      # run booked another's, and the silent direction is the expensive one: no
      # warning, the run starts, the month's budget goes.
      #
      # Three callers ask this same question about the same run — the P4b dialog
      # before it starts, Embeddings::SwitchProgress while it runs, and the gate at
      # the provider build that actually stops it. A hand-written copy per caller is
      # how the dialog comes to say "covered" about a run the page reports as paused.
      #
      # Raises like every other configured-lane resolution (MissingCredentialError <
      # Provider::Error) — an unresolvable lane is not a quota statement, and callers
      # rescue it as such rather than reading a nil as "free".
      # ⚠️ OMITTING `package:` and passing `package: nil` are DIFFERENT questions, the
      # same asymmetry #configured_descriptor and #resolve_embedding_credentials
      # already carry: omitted means "the lane this org is on now" (its curated
      # package, if any), while an explicit nil is the CUSTOM reading of E1-C — the
      # lane it would be on with no package at all. The P4b dialog needs the second
      # for the way back; Embeddings::SwitchProgress needs the first.
      # @param package [AiPackage, nil] the lane to judge; see the warning above
      # @return [AiCredential, nil] nil on BYOK
      def embedding_billing_credential(organisation, package: curated_package(organisation))
        configured_descriptor(organisation, package).credential
      end

      # Would routing this org through `package` MOVE its embedding lane? The ONE
      # answer both doors ask — the card grid (via AiPackage#embedding_switch_for?)
      # and Actors::SelectAiPackage — so the greyed-out card and the direct POST can
      # never disagree about what is on offer.
      #
      # `package: nil` is the DESELECTION question, and it is a real question: the
      # way back to "Eigene Konfiguration" can move the lane just as much as the way
      # in. The custom card asks it for exactly that reason.
      #
      # FAIL CLOSED on an unresolvable side: "cannot prove this is a no-op" and "is a
      # switch" need the same answer at the one guard standing between a customer and
      # a silently empty search.
      # @param package [AiPackage, nil] nil = the custom reading (E1-C)
      def embedding_switch?(organisation, package:)
        return false if organisation.nil?

        embedding_identity_for(organisation, package: package) != current_embedding_identity(organisation)
      rescue Provider::Error
        true
      end

      # The vector space an org writes into, as the pair that actually IDENTIFIES it:
      # the provenance triple AND the ENDPOINT the vectors come from.
      #
      # The triple alone does not identify the deployment, and P2 is what makes that
      # reachable for customers. Two openai_compatible credentials side by side
      # (Mistral FR next to IONOS DE — the normal case for the EU packages, §4.1)
      # serving the same model name at the same dimension produce an IDENTICAL triple.
      # A triple-only guard waves that move through as a no-op: every following vector
      # then comes from a different deployment, mixed into the same space, while the
      # jurisdiction badge keeps naming the package the customer picked. That is not a
      # performance detail — it is the Art. 13 statement the package is sold on.
      #
      # The ENDPOINT is the identity, deliberately NOT the credential id. A credential
      # row is a billing/pin fact, not a vector-space property: a curated package
      # almost always references its own row, so keying on the id would classify every
      # first package selection as a switch and freeze P2 whole instead of guarding it.
      # Two credentials pointing at the same api_base are the same deployment and their
      # vectors stay comparable; two different api_bases are two different services no
      # matter how alike the model names look. nil == nil covers the vendor-default
      # case (plain openai on both sides), which is exactly the same-lane pick P2 means
      # to allow.
      # @param package [AiPackage, nil] nil = the custom reading (E1-C)
      def embedding_identity_for(organisation, package:)
        embedding_identity_of(configured_descriptor(organisation, package), organisation)
      end

      # The identity of the space the org writes into TODAY — the "before" side.
      # A separate entry point rather than a default argument, because `package: nil`
      # already means "the custom reading" and must not collide with "whatever this
      # org currently has" (same reason #embedding_space_for and #embedding_triple_for
      # are two methods rather than one with a magic default).
      def current_embedding_identity(organisation)
        embedding_identity_of(configured_descriptor(organisation), organisation)
      end

      def embedding_identity_of(descriptor, organisation)
        { triple: ::Lalabase::Indexer::EmbeddingColumns.from(build_provider(descriptor, organisation)),
          api_base: descriptor.api_base.presence }
      end
      private_class_method :embedding_identity_of

      # Returns a provider for ONE specific HELD space, built from that space's own
      # credential snapshot — the roll-back path (review blocker B2).
      #
      # Why this exists next to #for_embeddings: a roll-back delta-reindexes a space
      # that is neither :active nor :configured (the pointer still names the new space,
      # the columns already name the new endpoint). Without the snapshot a BYOK org
      # would have to re-enter its old credentials mid-incident, which is precisely the
      # scenario B2 rejected the single-value snapshot for.
      def for_embedding_space(embedding_space, organisation)
        ensure_ai_enabled!(organisation)
        # Cross-tenant guard (review finding R4): a foreign space would contribute ITS
        # BYOK credential snapshot and stamp ITS triple. Unreachable through today's
        # only caller (the rollback task filters by organisation_id), but this method
        # becomes reachable from the 6b admin UI, and a credential crossing a tenant
        # boundary must fail loudly rather than depend on a caller's diligence.
        unless embedding_space.organisation_id == organisation&.id
          raise Provider::Error,
                "Embedding space #{embedding_space.id} does not belong to organisation #{organisation&.id.inspect}"
        end

        descriptor = descriptor_from_space(embedding_space)
        Gate.ensure_within_quota!(organisation, credential: descriptor.credential)
        build_provider(descriptor, organisation)
      end

      # The effective embedding credentials of the CONFIGURED space, for snapshotting
      # into an embedding_spaces row (Embeddings::EnsureSpace). Returns nil SECRETS on
      # the system-credential path on purpose — the snapshot must record "resolve the
      # system credential", not a copy of it, so a rotation keeps applying.
      #
      # ai_credential_id is the one system-path value that IS written, and it does not
      # break that contract: it is no secret, and it freezes no rotation — the token is
      # still resolved live off the credential record. What it freezes is the
      # ASSIGNMENT space→credential, which is exactly its purpose (P0,
      # doc/ki_pakete_plan.md §7b.2). See #space_credential for the failure it prevents.
      # @return [Hash] :api_base, :access_token, :organization_id, :ai_credential_id
      def embedding_credentials_for(organisation)
        package = curated_package(organisation)
        # A curated space is pinned to the PACKAGE's credential, never to the
        # provider's standard one — that assignment is exactly what the pin
        # freezes, and for the EU packages the two are routinely different rows
        # under one provider name (§7b.2). BYOK columns do not apply here: the
        # package governs this lane, so there is no own-secret case to snapshot.
        if package
          credential = package.embedding_credential
          return { api_base: nil, access_token: nil, organization_id: nil,
                   ai_credential_id: (credential.id if credential&.enabled?) }
        end

        provider_name = embedding_provider_name(organisation)
        if organisation_has_own_embedding?(organisation, provider_name)
          return { api_base: organisation.embedding_api_base,
                   access_token: organisation.embedding_access_token,
                   organization_id: organisation.embedding_organization_id,
                   # BYOK rows carry their own secret — no system credential to pin.
                   ai_credential_id: nil }
        end

        credential = AiCredential.active_for_provider(provider_name)
        # A credential that is missing or disabled leaves the pin NULL: the row then
        # keeps resolving by provider name and fails at build time exactly as it does
        # today, rather than pinning an id already known not to work.
        { api_base: nil, access_token: nil, organization_id: nil,
          ai_credential_id: (credential.id if credential&.enabled?) }
      end

      # Diagnostic seam for Embeddings::SpaceAlignment: does the ACTIVE space still
      # resolve the credential its reads run on?
      #
      # The alignment gate compares TRIPLES, and #embedding_space_for(:active) answers
      # from the snapshot row without ever touching a credential. So a space whose PIN
      # names a deleted, disabled or foreign-provider credential passes that gate as
      # "aligned" while every query embedding raises — the one failure mode the pin
      # introduced (P0) and the only one no check could see.
      #
      # Deliberately narrow: gate-free like #embedding_space_for (a read-only diagnostic
      # must not depend on ai_enabled or a quota), and nil for BYOK rows and orgs without
      # a pointer, which resolve no system credential at all. Goes through
      # #system_credentials rather than #space_credential so it exercises the SAME reads
      # the serving path does, including the access_token decryption.
      # @return [StandardError, nil] nil when the credential resolves or none is needed
      def active_space_credential_error(organisation)
        row = active_space_row(organisation)
        return nil if row.nil? || row.access_token.present?

        system_credentials(row)
        nil
      rescue StandardError => e
        e
      end

      # Everything needed to build a provider for ONE space: the routing key, the
      # model/dims to use, and the credentials to use them with. `credential` is
      # the resolved system AiCredential (nil on BYOK paths) — carried so the
      # quota gate and the usage attribution judge the SAME credential the call
      # runs on instead of re-resolving by provider name (P0).
      Descriptor = Struct.new(:provider_name, :model, :dims, :api_key, :organization_id,
                              :api_base, :additional_config, :credential, keyword_init: true)

      # @param space [Symbol] one of SPACES
      def embedding_descriptor(organisation, space)
        validate_space!(space)
        return configured_descriptor(organisation) unless space == :active

        active_descriptor(organisation) || configured_descriptor(organisation)
      end
      private_class_method :embedding_descriptor

      def validate_space!(space)
        return if SPACES.include?(space)

        raise ArgumentError, "Unknown embedding space #{space.inspect} (known: #{SPACES.join(', ')})"
      end
      private_class_method :validate_space!

      # The curated package's embedding slot, else the org BYOK columns, else the
      # system AiCredential. `package` is threaded rather than re-resolved so a
      # HYPOTHETICAL package (#embedding_triple_for) travels the identical path
      # as the org's real one — the comparison is only honest if both sides are
      # built by the same code.
      def configured_descriptor(organisation, package = curated_package(organisation))
        provider_name = package ? package.embedding_credential&.provider : org_embedding_provider_name(organisation)
        creds = resolve_embedding_credentials(provider_name, organisation, package)
        Descriptor.new(provider_name: provider_name, model: creds[:model],
                       dims: resolve_embedding_dims(organisation, creds[:additional_config], package),
                       api_key: creds[:api_key], organization_id: creds[:organization_id],
                       api_base: creds[:api_base], additional_config: creds[:additional_config],
                       credential: creds[:credential])
      end
      private_class_method :configured_descriptor

      # The SERVED space, rebuilt from its snapshot row. NULL credentials mean "resolve
      # the system credential" (B2) — the row deliberately stores no copy of it.
      # @return [Descriptor, nil] nil when the org has no pointer yet
      def active_descriptor(organisation)
        row = active_space_row(organisation)
        row && descriptor_from_space(row)
      end
      private_class_method :active_descriptor

      # A descriptor for any held space row. Shared by the active-space resolution and
      # the roll-back path, so both read a snapshot the same way.
      def descriptor_from_space(row)
        credentials = row.access_token.present? ? byok_credentials(row) : system_credentials(row)
        Descriptor.new(provider_name: row.embedding_provider, model: row.embedding_model,
                       dims: row.embedding_dims, **credentials)
      end
      private_class_method :descriptor_from_space

      def byok_credentials(row)
        { api_key: row.access_token, organization_id: row.organization_id,
          api_base: row.api_base, additional_config: nil, credential: nil }
      end
      private_class_method :byok_credentials

      def system_credentials(row)
        credential = space_credential(row)
        { api_key: credential.access_token, organization_id: credential.organization_id,
          # The row's own api_base wins: an operator may have snapshotted a specific
          # endpoint for this space even while its secret comes from the system.
          #
          # Falls back through #effective_api_base, NOT through the legacy
          # additional_config['uri_base'] alone: the curated snapshot deliberately
          # records no endpoint (embedding_credentials_for pins the credential id and
          # lets rotation keep applying), and the three EU presets fill the api_base
          # COLUMN. Reading only the legacy JSON key therefore built an endpoint-less
          # provider on the ACTIVE leg for exactly the packages P2 ships — configured
          # writes worked, query embeddings did not.
          api_base: row.api_base.presence || credential.effective_api_base,
          additional_config: credential.additional_config,
          # Whatever #space_credential resolved travels on, so the quota gate and the
          # usage attribution (P0) judge the credential the call actually runs on —
          # for a pinned row that is the PIN, not the provider's active slot.
          credential: credential }
      end
      private_class_method :system_credentials

      # Which system credential serves this space (P0, doc/ki_pakete_plan.md §7b.2).
      #
      # A PIN addresses exactly ONE credential and never degrades to the provider
      # default. With two openai_compatible system credentials side by side (Mistral FR
      # next to IONOS DE — the normal case for the EU packages), name resolution hands
      # the space built for one of them the OTHER one's key: the right snapshot endpoint
      # (row.api_base) with the wrong token, plus a mis-attributed metering record. That
      # silent swap is the bug this column exists to prevent, so a pin that no longer
      # resolves fails LOUDLY instead of being replaced.
      #
      # NULL is not a fault: rows written before the pin existed, and rows whose
      # credential was deleted (FK on_delete: :nullify degrades them back), mean "the
      # provider's default" and keep resolving by name. Deliberately not backfilled.
      #
      # The pin must also NAME THE SAME PROVIDER as the row. Unreachable while
      # EnsureSpace is the only writer (it pins what active_for_provider returned for
      # exactly this provider), but P1 hands the column to admin CRUD — and a google
      # credential pinned to an openai_compatible space would send a Vertex
      # service-account JSON as the bearer token to the row's endpoint. That fails as an
      # opaque 401 from a third party; the same failure class this column prevents, only
      # from the other side, so it is checked here rather than trusted to the caller.
      #
      # The PURPOSE is asked here too, not only on the :configured leg: one question
      # must have one answer. Without it the gate said no, the configured (write) leg
      # raised and the active (query) leg happily kept embedding search terms on the
      # same chat-only credential — three answers about one credential.
      def space_credential(row)
        if row.ai_credential_id.present?
          pinned = AiCredential.find_by(id: row.ai_credential_id)
          if pinned&.enabled? && pinned.provider == row.embedding_provider
            ensure_embedding_purpose!(pinned)
            return pinned
          end

          raise MissingCredentialError,
                "Pinned credential #{row.ai_credential_id} for embedding space #{row.id} is missing, " \
                "disabled or not a #{row.embedding_provider.inspect} credential " \
                '— refusing to fall back to the provider default'
        end

        credential = AiCredential.active_for_provider(row.embedding_provider)
        if credential&.enabled?
          ensure_embedding_purpose!(credential)
          return credential
        end

        raise MissingCredentialError,
              "No active credential configured for provider #{row.embedding_provider.inspect} " \
              "(active embedding space #{row.id})"
      end
      private_class_method :space_credential

      # Reads the pointer row WITHOUT going through organisation.active_embedding_space.
      #
      # That association carries acts_as_tenant's default scope, and this app runs
      # require_tenant = true (config/initializers/acts_as_tenant.rb): under a FOREIGN
      # ambient tenant the association would resolve to nil, and the caller would fall
      # back to the configured space — B1 broken again, by a different route and just
      # as silently. The explicit organisation_id predicate makes the read independent
      # of ambient state while keeping the cross-org guarantee (house style of
      # Embeddings::OrphanGc and Embeddings::SpaceAlignment).
      def active_space_row(organisation)
        return nil if organisation.nil? || organisation.active_embedding_space_id.blank?

        row = ActsAsTenant.without_tenant do
          ::EmbeddingSpace.find_by(id: organisation.active_embedding_space_id,
                                   organisation_id: organisation.id)
        end
        warn_dangling_pointer(organisation) if row.nil?
        row
      end
      private_class_method :active_space_row

      # A pointer that is SET but resolves to nothing is a data fault, not a fresh org:
      # the row was deleted (the FK nullifies on delete, so this needs a lost UPDATE or a
      # cross-org id) while the column still names it. The caller falls back to the
      # configured space — better than raising on every query — but the fallback would
      # otherwise be indistinguishable from the legitimate "no pointer yet" case, and the
      # org would quietly serve from a space nobody chose (review finding R3).
      def warn_dangling_pointer(organisation)
        Rails.logger.warn(
          "Lalabase::Llm::Factory: organisation #{organisation.id} points at embedding space " \
          "#{organisation.active_embedding_space_id}, which does not resolve — falling back to the " \
          'configured space. Check organisations.active_embedding_space_id.'
        )
      end
      private_class_method :warn_dangling_pointer

      # Provider construction from a descriptor. Pure ivar assignment — no API call,
      # no validation.
      def build_provider(descriptor, organisation)
        klass = PROVIDER_CLASSES.fetch(descriptor.provider_name) do
          raise Provider::Error, "Unknown LLM provider: #{descriptor.provider_name.inspect}"
        end
        klass.new(api_key: descriptor.api_key, organisation_id_param: descriptor.organization_id,
                  organisation: organisation, uri_base: descriptor.api_base,
                  embedding_model: descriptor.model, additional_config: descriptor.additional_config,
                  embedding_dims: descriptor.dims, billing_credential: descriptor.credential,
                  operator_endpoint: operator_endpoint?(descriptor.api_base, descriptor.credential))
      end
      private_class_method :build_provider

      # Did an operator choose this endpoint? Only when it is exactly the one an
      # AiCredential names. A BYOK endpoint comes with no credential, and a space row
      # whose own api_base differs from its credential's is not the operator's choice
      # either. Everything that is not provably the operator's is judged again for every
      # request (PublicEndpointAdapter); a self-hosted model server next to the app
      # belongs on a system credential for exactly that reason.
      def operator_endpoint?(api_base, credential)
        credential.present? && api_base.present? && api_base == credential.effective_api_base
      end
      private_class_method :operator_endpoint?

      # `utility:` selects the package rung the credentials come from (P3); it is
      # meaningless on the PINNED path, which by definition does not run on the
      # org's package at all — see #resolve_credentials, where a rung of a
      # different provider is skipped either way.
      def build(provider_name:, organisation:, utility: false)
        ensure_ai_enabled!(organisation)
        klass = chat_provider_class(provider_name)
        creds = resolve_credentials(provider_name, organisation, utility: utility)
        # Quota gate (S3): covers for_chat AND the direct-build callers (summary /
        # ticket summary / customer description), so no chat-side path bypasses the
        # gate (test 27). AFTER the opt-in gate; inert for BYOK / non-quota creds.
        # Judged on the JUST-resolved credential (P0), not a second name-based
        # lookup — the gate must gate the credential the call will actually bill.
        # Error precedence is unchanged: with no usable credential, resolution
        # raises MissingCredentialError and the quota question never arises.
        Gate.ensure_within_quota!(organisation, credential: creds[:credential])
        instantiate_chat(klass, creds, organisation)
      end

      # The DIAGNOSTIC twin of #build: the very provider this org's chat would run
      # on, built WITHOUT the two gates (S7/E3, gap L6).
      #
      # Gate-free on purpose, and the reasoning is the same one
      # #active_space_credential_error and AiCredentialConnectivity already state:
      # Provider#connectivity_check lists models or verifies a key. It sends no tenant
      # content, spends no tokens and books nothing against the quota, so it is an
      # operator diagnostic rather than inference on somebody's data — the one thing the
      # opt-in gate exists to hold back.
      #
      # Without this seam the check answered the wrong question twice over. L6: the
      # natural order is "configure first, switch on afterwards", so the probe raised
      # AiDisabledError for exactly the organisation that was trying to set itself up,
      # and QuotaExceededError for the one whose budget was gone — neither of which says
      # anything about whether the access works. And it is the ONLY way the hub card can
      # ever show "Verbindung fehlerhaft" for an organisation that has AI switched off.
      #
      # Deliberately NOT a second credential resolution: same #resolve_credentials, same
      # rung, same package branch as the real call. A probe that resolved its own
      # credentials would be free to report a green result for a credential no request
      # ever uses, which is precisely the class of defect L5 describes on the other axis.
      #
      # @return [Lalabase::Llm::Provider] never nil — raises like #build does
      #   (MissingCredentialError, Provider::Error) so the caller can name the cause.
      def chat_probe(organisation)
        provider_name = chat_provider_name(organisation)
        klass = chat_provider_class(provider_name)
        instantiate_chat(klass, resolve_credentials(provider_name, organisation), organisation)
      end

      # Split out of #build so the probe above cannot drift from it. Kept as two
      # methods rather than one, because the ORDER in #build is load-bearing: an
      # unknown provider must raise before #resolve_credentials gets a chance to raise
      # MissingCredentialError, otherwise the error names the wrong cause.
      def chat_provider_class(provider_name)
        PROVIDER_CLASSES.fetch(provider_name) do
          raise Provider::Error, "Unknown LLM provider: #{provider_name.inspect}"
        end
      end
      private_class_method :chat_provider_class

      def instantiate_chat(klass, creds, organisation)
        klass.new(api_key: creds[:api_key], organisation_id_param: creds[:organization_id],
                  organisation: organisation, uri_base: creds[:api_base],
                  chat_model: creds[:chat_model], provider_name: creds[:display_name],
                  additional_config: creds[:additional_config],
                  billing_credential: creds[:credential],
                  operator_endpoint: operator_endpoint?(creds[:api_base], creds[:credential]))
      end
      private_class_method :instantiate_chat

      # Resolves the chat credentials + routing/config for a provider.
      # @return [Hash] :api_key, :organization_id, :api_base (uri_base for
      #   OpenAI-compatible endpoints), :chat_model (whoever OWNS the key names the
      #   model — see the three branches below; nil lets the provider fall back to its
      #   constant), :display_name (effective attribution name),
      #   :additional_config (non-secret routing extras — google project_id/location;
      #   nil on the BYOK path, org columns carry no such config), :credential (the
      #   resolved system AiCredential feeding gate + attribution; nil on BYOK).
      def resolve_credentials(provider_name, organisation, utility: false)
        tier = curated_tier(curated_package(organisation), organisation, utility: utility)
        # The package governs the org's OWN lane, not a pinned one: for_feature
        # builds a pinned provider BY NAME (feature.pin), and handing that build
        # the package credential of a DIFFERENT provider would send e.g. a Mistral
        # token to OpenAiProvider — the silent wrong-token swap the P0 pin exists
        # to prevent, arriving from the other side. Comparing the provider is also
        # what keeps this ONE branch: a nil tier (custom, or no package) falls
        # through to the two existing branches below, which is what "custom
        # subsumes BYOK + system" means (§6.1 Detailkonflikt 2).
        return curated_chat_resolution(tier) if tier&.chat_credential&.provider == provider_name

        if organisation_has_own?(organisation, provider_name)
          # BYOK: the org's own token + own chat api_base — and THEREFORE the org's own
          # preferred_chat_model. This is the ONE branch that reads that column, which is
          # the whole rule: whoever's key pays for the request names the model on it.
          {
            api_key: organisation.ai_access_token,
            organization_id: organisation.ai_organization_id,
            api_base: organisation.try(:ai_api_base),
            chat_model: organisation.try(:preferred_chat_model).presence,
            display_name: nil,
            additional_config: nil,
            credential: nil
          }
        else
          credential = AiCredential.active_for_provider(provider_name)
          unless credential&.enabled?
            raise MissingCredentialError,
                  "No active credential configured for provider #{provider_name.inspect}"
          end
          # ⚠️ The SYSTEM key, therefore the SYSTEM model. organisation
          # .preferred_chat_model deliberately does NOT take part — same rule and same
          # reason as the curated branch above (§6.1 Detailkonflikt 1), which this branch
          # broke until the review of S7.
          #
          # It used to win here too, which was harmless only for as long as the column
          # was reachable from a console alone. S7 turns it into a free text field on the
          # customer's own configuration screen, and the two branches are NOT mutually
          # exclusive from the customer's side: an org on BYOK openai_compatible still
          # lands here for every seam pinned to `openai` (:customer_description is one),
          # because has_own_ai_credentials?('openai') is false for it. Measured before the
          # fix: api_key = the operator's system key, chat_model = "o3-pro-expensive".
          #
          # Two things went with that, and the second is the quieter one: the customer
          # picked which model runs on OUR invoice, and the pin was defeated — a pin
          # names a model because REASONING_MODEL_PATTERN switches the request dialect,
          # so overriding it is not a matter of taste but a broken request.
          {
            api_key: credential.access_token,
            organization_id: credential.organization_id,
            api_base: credential.effective_api_base,
            chat_model: credential.default_model,
            display_name: credential.try(:display_name).presence,
            additional_config: credential.additional_config,
            credential: credential
          }
        end
      end

      # The curated chat leg: the rung's credential, addressed BY ID. Never
      # active_for_provider — that is the whole point of P0. With two
      # openai_compatible system credentials side by side (Mistral FR next to
      # IONOS DE, the normal case for the EU packages) name resolution hands the
      # org the OTHER provider's key: right endpoint, wrong token, plus a
      # mis-attributed usage record (§4.1).
      #
      # The model is the RUNG's (AiPackageTier#effective_chat_model:
      # tier.chat_model > credential.default_model) and
      # organisation.preferred_chat_model does NOT take part — §6.1
      # Detailkonflikt 1. A value left over from the org's pre-package days would
      # otherwise silently override the rung the customer just picked, and the
      # column it comes from is not even shown on the package screen.
      #
      # Asked through #usable_for?(:chat) rather than `enabled?` alone: the embedding
      # twin has demanded a matching PURPOSE since R1 and an endpoint since S2, while
      # this leg asked neither. A referenced credential edited from 'both' to
      # 'embedding' — or one whose api_base was cleared — stayed "available" to every
      # org on the package and then mis-billed or raised inside the provider. Same
      # three conditions on both lanes now, stated once on the record.
      def curated_chat_resolution(tier)
        credential = tier.chat_credential
        unless credential.usable_for?(:chat)
          raise MissingCredentialError,
                "Credential #{credential.id} of package tier #{tier.key.inspect} cannot serve chat " \
                "(enabled: #{credential.enabled?}, purpose: #{credential.purpose.inspect}, " \
                "endpoint: #{credential.effective_api_base.inspect})"
        end

        { api_key: credential.access_token,
          organization_id: credential.organization_id,
          api_base: credential.effective_api_base,
          chat_model: tier.effective_chat_model,
          display_name: credential.try(:display_name).presence,
          additional_config: credential.additional_config,
          credential: credential }
      end
      private_class_method :curated_chat_resolution

      # NOTE: the endpoint rule moved to AiCredential#effective_api_base
      # (AiCredentialProviderRules). It lived here as a Factory helper and was
      # therefore re-implemented in Organisation#system_embedding_credential_usable?,
      # which read the legacy JSON key alone — the Factory routed a column-only
      # credential happily while the gate told the customer search was unavailable.
      # One definition on the record both sides already hold.

      # NOTE: #chat_model_precedence is gone (review of S7). It was the ONE helper both
      # branches of #resolve_credentials shared, and sharing it was the defect: an
      # org-level column has a meaning on the org's own key and no business on anybody
      # else's. Each branch now names its own model inline, which is three lines and
      # removes the place where the two could be confused again.
      #
      # ⚠️ OPEN, and deliberately not fixed here — the rule above holds for what the
      # Factory RESOLVES, not for what a caller does with the provider afterwards.
      # ChatResponseJob#generate_answer hands the Runner
      # `model: chat.organisation.preferred_chat_model.presence`, the Runner forwards it
      # as `model:` into provider#chat, and every provider does `model ||=
      # default_chat_model` — so a non-nil value WINS over whatever was resolved here.
      # Measured: the same customer-editable column therefore still names the model on
      # the operator's system key, and it also overrides a package rung's
      # effective_chat_model, which §6.1 Detailkonflikt 1 forbids. The fix is to drop the
      # override (nil lets the provider use its resolved chat_model, which is identical
      # for BYOK and correct everywhere else); it is a live-traffic change on the main
      # chat surface and belongs to its own decision, not to this review.

      # GDPR org-level opt-in gate (audit 2026-07-03, item 1.2): no tenant content
      # may leave towards an LLM provider unless an org admin explicitly enabled
      # AI features.
      #
      # Enforcement model — read before "cleaning up" checks elsewhere:
      # * This raise is the BACKSTOP GUARANTEE. The legacy seam
      #   Organisation#ai_client delegates here, so both seams share one
      #   implementation.
      # * Pipeline entry points (EmbeddingProcessingService, indexer jobs,
      #   reindex/reprocessing services) additionally PRE-check ai_enabled? —
      #   those are quiet-skip/UX optimisations so jobs don't fail on an
      #   expected state. They may be removed without opening a bypass;
      #   this gate may not.
      def ensure_ai_enabled!(organisation)
        return if organisation&.ai_enabled?

        raise AiDisabledError, "AI features are not enabled for organisation #{organisation&.id || '(none)'}"
      end

      def organisation_has_own?(organisation, provider_name)
        organisation.respond_to?(:has_own_ai_credentials?) &&
          organisation.has_own_ai_credentials?(provider_name)
      end

      # The CONFIGURED embedding provider: the package's embedding credential
      # when one governs, else the org's own choice — i.e. where new embeddings
      # go, not necessarily where search reads (that is the :active space).
      # Public for the same reason as #chat_provider_name — the feature
      # registry reads it, and a second derivation is a second answer. The
      # Art. 13 notice deliberately does NOT read it any more: it names the
      # search's recipient via routing_disclosure (P5 review, MAJOR 1).
      def embedding_provider_name(organisation)
        package = curated_package(organisation)
        return package.embedding_credential&.provider if package

        org_embedding_provider_name(organisation)
      end

      # The custom leg alone (org column, defaulting to OpenAI = prior behaviour).
      def org_embedding_provider_name(organisation)
        (organisation&.embedding_provider.presence || ::AiCredential::PROVIDER_OPENAI).downcase
      end
      private_class_method :org_embedding_provider_name

      # Embedding credentials live in their OWN org columns (embedding_*), separate
      # from chat. Falls back to the system AiCredential for the provider.
      # @return [Hash] :api_key, :organization_id, :api_base, :model,
      #   :additional_config (nil on the BYOK path — org columns carry no such
      #   config, so a google BYOK embedding setup fails fast in the provider),
      #   :credential (resolved system AiCredential; nil on BYOK).
      def resolve_embedding_credentials(provider_name, organisation, package = curated_package(organisation))
        credential = package&.embedding_credential
        return curated_embedding_resolution(package, credential) if credential&.provider == provider_name

        if organisation_has_own_embedding?(organisation, provider_name)
          { api_key: organisation.embedding_access_token,
            organization_id: organisation.embedding_organization_id,
            api_base: organisation.embedding_api_base,
            model: organisation.embedding_model,
            additional_config: nil, credential: nil }
        else
          credential = AiCredential.active_for_provider(provider_name)
          unless credential&.enabled?
            raise MissingCredentialError,
                  "No active credential configured for provider #{provider_name.inspect}"
          end
          ensure_embedding_purpose!(credential)
          { api_key: credential.access_token,
            organization_id: credential.organization_id,
            # Column first, legacy JSON second (#effective_api_base) — the same
            # precedence the curated leg and #space_credential use. Reading only
            # additional_config['uri_base'] here left a system openai_compatible
            # credential that fills the api_base COLUMN (every row written since S2,
            # and all three EU presets) with no endpoint at all, which the provider
            # then raised on. It also made the endpoint invisible to the switch
            # guard, whose whole job is telling two deployments apart.
            api_base: credential.effective_api_base,
            model: credential.default_model,
            additional_config: credential.additional_config, credential: credential }
        end
      end

      # The curated embedding leg. Two things are taken from the PACKAGE, not
      # from the credential (E11): the model VERBATIM and the dimension — the
      # package owns the whole vector-space triple, so a model change on a shared
      # credential can no longer move the embedding lane (and with it the reindex
      # obligation) of every package that references it.
      #
      # api_base reads the column first (#effective_api_base), unlike the system
      # leg above, which only knows the legacy additional_config['uri_base']. The
      # EU presets fill the COLUMN, so a curated Mistral package resolved the
      # legacy way would build an endpoint-less provider.
      #
      # KNOWN LIMIT, not a bug of this branch: the model is verbatim in the CALL,
      # but the provenance stamp derived from the built provider
      # (Indexer::EmbeddingColumns → Provider#default_embedding_model) comes from
      # a CONSTANT for openai and google. A curated package on those two providers
      # therefore stamps its spaces with the constant, not with embedding_model.
      # Pre-existing (the same is true of an org's own embedding_model column) and
      # deliberately not repaired here: changing it would relabel every existing
      # space, i.e. make every stamped row stale at once.
      def curated_embedding_resolution(package, credential)
        # nil-guard (adversarial review P2-B1): a custom-kind row carries no
        # embedding credential, and `nil == nil` on the provider match would
        # otherwise route it here and die on NoMethodError instead of the
        # domain error every caller of this seam knows how to handle.
        if credential.nil?
          raise MissingCredentialError,
                "Package #{package.name.inspect} references no embedding credential"
        end
        unless credential.enabled?
          raise MissingCredentialError,
                "Embedding credential #{credential.id} of package #{package.name.inspect} is disabled"
        end
        ensure_embedding_purpose!(credential)

        { api_key: credential.access_token,
          organization_id: credential.organization_id,
          api_base: credential.effective_api_base,
          model: package.embedding_model,
          additional_config: credential.additional_config, credential: credential }
      end
      private_class_method :curated_embedding_resolution

      # Gate and routing must judge the same call the same way. The gate
      # (Organisation#has_valid_embedding_configuration?) has asked for an
      # EMBEDDING purpose since R1, while this resolution asked only for
      # `enabled` — so a chat-only credential made the gate say no while the
      # factory happily built an embedder on it, and the mismatch surfaced as a
      # provider-side error far from its cause.
      #
      # BEHAVIOUR CHANGE on the custom path, deliberately: a system credential
      # with purpose 'chat' used to carry embeddings and now raises. It is the
      # same refusal the gate already spoke, moved to where the call happens.
      def ensure_embedding_purpose!(credential)
        return if AiCredentialPricing::EMBEDDING_PURPOSES.include?(credential.purpose)

        raise MissingCredentialError,
              "Credential #{credential.id} (#{credential.provider}) has purpose " \
              "#{credential.purpose.inspect} and cannot serve embeddings"
      end
      private_class_method :ensure_embedding_purpose!

      def organisation_has_own_embedding?(organisation, provider_name)
        organisation.respond_to?(:has_own_embedding_credentials?) &&
          organisation.has_own_embedding_credentials?(provider_name)
      end

      # Embedding-dim precedence (doc/embedding_v2_multidim_plan.md §3.2):
      # org.embedding_dims > credential additional_config['embedding_dims'] >
      # provider default. Returns nil when NEITHER is set — the provider then
      # falls back to DEFAULT_EMBEDDING_DIMS in its guard and sends no explicit
      # dimension param, keeping the request byte-identical to pre-v2. The dim is
      # part of the vector-space triple: a 1024-space must reject a 1536 vector.
      #
      # `credential_config` is the system credential's additional_config (nil on
      # the org BYOK path) — admin-entered, UNVALIDATED JSON, so it passes the
      # same gate as the validated org column: strict Integer parsing (garbage
      # never becomes 0, non-numeric types never raise) + the SUPPORTED_DIMS
      # allowlist. An out-of-range value (a dimension with no storage lane, or a
      # plain typo) is IGNORED with a warn log instead of raising, so one credential typo
      # cannot take down embeddings for every org on that credential — the effective
      # dim then falls back to the default.
      # `package` (E11): a curated package's dimension wins outright — it is the
      # half of the triple that has to match its model, and the two are validated
      # side by side on the package. The org column is not consulted as a
      # fallback: a leftover 1536 there must not silently reshape a 1024 package.
      def resolve_embedding_dims(organisation, credential_config, package = nil)
        explicit = if package
                     package.embedding_dims
                   else
                     organisation.try(:embedding_dims) || credential_config&.dig('embedding_dims')
                   end
        # Integer(exception: false) returns nil for garbage strings AND wrong
        # types (false/Array/Hash raise TypeError → nil) — unlike .to_i, which
        # turns 'abc' into 0 and raises NoMethodError on non-numerics.
        dims = Integer(explicit, exception: false)
        return dims if dims && ::Organisation::SUPPORTED_DIMS.include?(dims)

        unless explicit.nil?
          Rails.logger.warn(
            "Lalabase::Llm::Factory: ignoring unsupported embedding_dims #{explicit.inspect} " \
            "(allowed: #{::Organisation::SUPPORTED_DIMS.join(', ')})"
          )
        end
        nil
      end
    end
  end
end
