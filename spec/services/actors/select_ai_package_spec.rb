# frozen_string_literal: true

require 'rails_helper'

# What this file protects (doc/ki_pakete_plan.md §6.1/§7/§8, decision 2026-08-02)
# -----------------------------------------------------------------------------
# 1. The choice and its PROTOCOL are written together. "EU is the default, US the
#    deliberate deviation" is only auditable if the deviation carries a name and
#    a timestamp (§7).
# 2. Only a PUBLISHED, CURATED package can be chosen. `active` is the operator's
#    shop-window switch; `custom` is the placeholder for having no package, and
#    the way back to it is deselection, not selection.
# 3. THE refusal of P2: a change that moves the org's effective embedding triple
#    is blocked until P4's guided switch exists. Stated as a property of the
#    TRIPLE, never of the package, so it covers selection, switching AND
#    deselection with one rule — and so a package that happens to share the
#    current triple stays freely selectable.
RSpec.describe Actors::SelectAiPackage do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # The org's CURRENT lane: the system openai credential every org without its
  # own configuration resolves to.
  let!(:openai_standard) { create(:ai_credential, :active, provider: 'openai', region: 'eu') }

  # ONE CREDENTIAL PER RUNG, and that is load-bearing, not tidiness. With both
  # rungs on a single credential every "the actor judges the rung it was ASKED
  # about" example passes for the wrong reason: disabling "the thorough
  # credential" disables fast in the same statement, so a mutation that asked
  # #default_selection_tier — or any rung at all — instead of the requested one
  # stays green. Two rows make the question answerable at all.
  let!(:eu_chat) do
    create(:ai_credential, :openai_compatible, :eu_company,
           name: 'Mistral FR chat', default_model: 'mistral-small-latest',
           access_token: 'mistral-chat-token-123456')
  end

  let!(:eu_chat_thorough) do
    create(:ai_credential, :openai_compatible, :eu_company,
           name: 'Mistral FR large', default_model: 'mistral-large-latest',
           access_token: 'mistral-large-token-123456')
  end

  # Same provider on both rungs on purpose: the rung must be distinguishable by
  # CREDENTIAL alone, so an example that passes only because the provider name
  # also changed cannot hide here.
  def chat_credential_for(key)
    key == AiPackageTier::DEFAULT_KEY ? eu_chat : eu_chat_thorough
  end

  # An embedding credential that resolves to the SAME triple the org is on
  # already (openai / text-embedding-3-small / 1536): the package whose search
  # half changes nothing, i.e. the one P2 may hand to the customer.
  let!(:same_lane_embedding) do
    create(:ai_credential, :embedding_only, provider: 'openai', region: 'eu',
                                            name: 'OpenAI embeddings', access_token: 'sk-embed-token-1234567890')
  end

  # Published LAST, because a published package must already carry the full
  # ladder — the same order the admin form produces.
  def build_package(embedding_credential:, model: 'text-embedding-3-small', dims: 1536, published: true)
    package = create(:ai_package, embedding_credential: embedding_credential, embedding_model: model,
                                  embedding_dims: dims, active: false)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers.create!(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                            position: index, chat_credential: chat_credential_for(key))
    end
    package.update!(active: true) if published
    package
  end

  # Same vector-space triple as the org's current one — only the CHAT half moves.
  let(:same_lane_package) { build_package(embedding_credential: same_lane_embedding) }

  # A 1024-dim Mistral lane: the switch that needs a reindex.
  let(:other_lane_package) do
    embedding = create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
                       name: 'Mistral FR embed', default_model: 'mistral-embed',
                       access_token: 'mistral-embed-token-123')
    build_package(embedding_credential: embedding, model: 'mistral-embed', dims: 1024)
  end

  def select(package_id, tier_key = nil)
    described_class.call(organisation: organisation, current_user: user,
                         params: { ai_package_id: package_id, ai_package_tier_key: tier_key })
  end

  describe 'the happy path' do
    it 'stores the choice and the protocol in one write' do
      result = select(same_lane_package.id, 'thorough')

      expect(result).to be_success
      expect(organisation.reload).to have_attributes(
        ai_package_id: same_lane_package.id, ai_package_tier_key: 'thorough',
        ai_package_selected_by_id: user.id
      )
      expect(organisation.ai_package_selected_at).to be_within(5.seconds).of(Time.current)
    end

    it 'defaults to the fast rung when none is given (P3 ships the switch)' do
      select(same_lane_package.id)

      expect(organisation.reload.ai_package_tier_key).to eq('fast')
    end

    # The write is what makes the choice REACH the routing — without this the
    # actor would be a bookkeeping exercise.
    it 'moves the chat lane onto the package provider' do
      select(same_lane_package.id)

      expect(Lalabase::Llm::Factory.chat_provider_name(organisation.reload)).to eq('openai_compatible')
    end

    # Organisation is not Trackable, so nothing writes an audit trail by callback —
    # which is why the protocol columns are set in the same statement as the choice.
    # Since P4e a targeted Activity carries the HISTORY beside them (see "the protocol
    # trail" below); the columns still hold the LAST choice.
    it 'sets Current.user through the base actor without leaking it' do
      previous = Current.user
      select(same_lane_package.id)

      expect(Current.user).to eq(previous)
    end
  end

  describe 'what may not be chosen' do
    it 'refuses an unknown id' do
      result = select(SecureRandom.uuid)

      expect(result).not_to be_success
      expect(result.code).to eq(:package_not_found)
      expect(organisation.reload.ai_package_id).to be_nil
    end

    it 'refuses an unpublished package' do
      draft = build_package(embedding_credential: same_lane_embedding, published: false)

      expect(select(draft.id).code).to eq(:package_not_published)
    end

    it 'refuses a custom package — the way back is deselection' do
      custom = AiPackage.create!(kind: 'custom', name: 'Eigene Konfiguration', active: true)

      expect(select(custom.id).code).to eq(:package_not_curated)
    end

    it 'refuses a rung outside the ladder' do
      expect(select(same_lane_package.id, 'premium').code).to eq(:unknown_tier)
    end

    # Only reachable as DRIFT: the ladder validation keeps a published package
    # from missing a rung, so this state has to be built the way it would have
    # arisen — published before that validation existed. Defense in depth, and
    # the reason the actor asks the PACKAGE and not just the KEYS list.
    it 'refuses a valid rung this package does not offer' do
      package = create(:ai_package, embedding_credential: same_lane_embedding,
                                    embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
      package.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0, chat_credential: eu_chat)
      package.update_columns(active: true)

      expect(select(package.id, 'thorough').code).to eq(:tier_not_offered)
    end

    it 'reports the rung it rejected, not just that something was wrong' do
      expect(select(same_lane_package.id, 'premium').errors.join).to include('premium')
    end
  end

  # The centre of this file, and P4a turned it around: the very question that
  # produced :embedding_switch_blocked now produces the MIGRATION. What is pinned
  # here is therefore no longer "who is refused" but "who gets a reindex" — same
  # rule, opposite consequence, and the danger moved with it. Under P2 a wrong
  # answer refused a legitimate switch (visible, annoying); under P4a it either
  # moves an org's lane WITHOUT rebuilding its index (silently empty search) or
  # spends a customer's quota on a reindex that changes nothing.
  describe 'the embedding switch is started (P4a)' do
    # House pattern for actors that enqueue (create_chatpost_spec,
    # flip_embedding_model_spec): the real adapter is Solid Queue, which has no
    # inspectable enqueue list.
    around do |example|
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = original
    end

    it 'builds the target space and queues the reindex for a package on another lane' do
      expect { select(other_lane_package.id) }
        .to have_enqueued_job(Embeddings::ReindexOrganisationJob).with(organisation).once

      expect(organisation.reload.ai_package_id).to eq(other_lane_package.id)
      # EnsureSpace ran for the NEW triple. Asserting the ROW (not the call) is
      # what makes this fail if the space were built before the write lands —
      # at that moment the configured triple is still the one being left.
      expect(EmbeddingSpace.where(organisation: organisation).last)
        .to have_attributes(embedding_provider: 'openai_compatible', embedding_model: 'mistral-embed',
                            embedding_dims: 1024)
    end

    it 'starts nothing when the package leaves the triple untouched' do
      # What makes this a guard rather than a blanket reindex: a switch whose
      # search half does not move must not cost the customer anything.
      expect { expect(select(same_lane_package.id)).to be_success }
        .not_to have_enqueued_job(Embeddings::ReindexOrganisationJob)
    end

    # Falle 4 (plan §5), and it is not cosmetic: Factory raises AiDisabledError for
    # such an org, #embedding_switch? rescues that to `true` (fail closed), and
    # EnsureSpace would then raise it AFTER the commit, where no Result maps it.
    # The package choice itself must still land.
    it 'writes the choice but starts nothing when the AI opt-in is off' do
      organisation.update!(ai_enabled: false)

      expect { expect(select(other_lane_package.id)).to be_success }
        .not_to have_enqueued_job(Embeddings::ReindexOrganisationJob)
      expect(organisation.reload.ai_package_id).to eq(other_lane_package.id)
      expect(EmbeddingSpace.where(organisation: organisation)).to be_empty
    end

    # The read lane is NOT touched here — that is the whole of E5 ("seamless").
    # Search keeps answering from the old space until the new one is complete;
    # P4d's watcher decides that against its own completeness check. An actor that
    # flipped the pointer would hand the customer an empty index for the duration
    # of the rebuild.
    it 'does not flip the active space — search keeps reading the old one' do
      expect { select(other_lane_package.id) }
        .not_to(change { organisation.reload.active_embedding_space_id })
    end

    # A rung is a COST decision and never touches the embedding lane (§2, the
    # plan's central claim) — if this ever blocked, the two axes would have grown
    # back together.
    it 'never blocks a rung change within one package' do
      select(same_lane_package.id, 'fast')

      expect(select(same_lane_package.id, 'thorough')).to be_success
      expect(organisation.reload.ai_package_tier_key).to eq('thorough')
    end

    it 'starts one for a switch BETWEEN two packages of different lanes' do
      # The same-lane hop first, INSIDE the block on purpose: it must contribute
      # nothing, so `.once` also proves the guard did not wave both writes through.
      expect do
        select(same_lane_package.id)
        expect(select(other_lane_package.id)).to be_success
      end.to have_enqueued_job(Embeddings::ReindexOrganisationJob).once

      expect(organisation.reload.ai_package_id).to eq(other_lane_package.id)
    end

    # The rule is "does the effective TRIPLE change", and on openai the effective
    # model is NOT the declared one: OpenAiProvider answers
    # #default_embedding_model from a CONSTANT (factory.rb, "KNOWN LIMIT"). Two
    # openai packages differing only in embedding_model therefore resolve to the
    # SAME triple and the switch is free.
    #
    # Pinned because it looks like a bug from the outside and is the deliberate
    # consequence of comparing DERIVED triples on both sides. Whoever makes the
    # provider honour the configured model has to expect this example to flip —
    # and, with it, the reindex obligation of every openai package.
    it 'allows a package that only renames the model its provider ignores anyway' do
      renamed = build_package(embedding_credential: same_lane_embedding, model: 'text-embedding-ada-002')

      expect(select(renamed.id)).to be_success
    end

    # The other half of that asymmetry, and the reason it may not be simplified
    # to "same dims ⇒ same lane": OpenAiCompatibleProvider — the rail all three EU
    # presets run on (§4.1) — returns the CONFIGURED model, so there the name
    # alone moves the vector space even at an identical dimension.
    it 'reindexes an openai_compatible package that only changes the model name' do
      current = other_lane_package
      organisation.update!(ai_package: current, ai_package_tier_key: 'fast')
      successor_credential = create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
                                    name: 'Mistral FR embed v2', default_model: 'mistral-embed',
                                    access_token: 'mistral-embed-token-456')
      successor = build_package(embedding_credential: successor_credential,
                                model: 'mistral-embed-v2', dims: 1024)

      expect { expect(select(successor.id)).to be_success }
        .to have_enqueued_job(Embeddings::ReindexOrganisationJob).once
    end
  end

  # `active` is the operator's shop-window switch and nothing else (§7b.1): it
  # governs what NEW customers are offered, never how an existing one routes
  # (pinned on the routing side in factory_spec).
  #
  # Until P4a it did not give an org already on the package a way out either: the
  # embedding block judged the TRIPLE, and a withdrawn package's triple differs
  # from the org's own columns like any other, so the exit was refused. P4a is
  # what opens it — deselecting now starts the migration back instead of being
  # turned away. That is the "geführter Ausgang" of E5, and it is the half of the
  # withdrawn-package repair that lives in the actor; the other half (making the
  # card visible at all) is P4c.
  describe 'a package the operator has withdrawn from the catalogue' do
    around do |example|
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = original
    end

    before do
      organisation.update!(ai_package: other_lane_package, ai_package_tier_key: 'fast')
      other_lane_package.update_columns(active: false)
    end

    it 'can now be left by deselecting, and the way back is migrated (P4a)' do
      result = nil
      expect do
        result = described_class.call(organisation: organisation, current_user: user,
                                      params: { ai_package_id: '' })
      end.to have_enqueued_job(Embeddings::ReindexOrganisationJob).once

      expect(result).to be_success
      expect(organisation.reload.ai_package_id).to be_nil
    end

    # P3 briefly exempted a pure rung change here and the review took it back.
    # Two facts decided it, and both are pinned so the exemption cannot quietly
    # return:
    #
    # 1. It reached nobody. The switcher renders only from the published,
    #    filtered catalogue, so a withdrawn package has no card and no switcher —
    #    the permission was reachable by hand-built POST alone
    #    (spec/requests/organisations/ai_settings_packages_spec.rb asserts the
    #    card is gone for exactly this state).
    # 2. It opened a hole. #published_package_must_carry_the_full_ladder validates
    #    `if curated? && active?`, so an UNPUBLISHED package may legitimately lose
    #    a rung — and writes onto that package were the ones the exemption let
    #    through, straight into the silent cost fallbacks of Factory#curated_tier
    #    and AiPackage#utility_tier.
    #
    # Unfreezing the customer is a UI job (render the current card outside the
    # filters), and it belongs with P4's guided switch, which is the actual exit.
    it 'refuses a rung change too — `active` governs every write, not just entry' do
      result = select(other_lane_package.id, 'thorough')

      expect(result.code).to eq(:package_not_published)
      expect(organisation.reload.ai_package_tier_key).to eq('fast')
      expect(organisation.ai_package_id).to eq(other_lane_package.id)
    end

    # The outsider's half of the same rule. The tier_key is sent DELIBERATELY:
    # if the guard were ever re-written as "a tier_key was sent" rather than as a
    # property of `active`, a stranger posting a rung is the closest anyone can
    # get to looking like an existing customer — and this is the example that
    # catches it.
    it 'refuses an org that is not on it, even with a rung in the request' do
      stranger = create(:organisation)
      result = described_class.call(organisation: stranger, current_user: user,
                                    params: { ai_package_id: other_lane_package.id,
                                              ai_package_tier_key: 'thorough' })

      expect(result.code).to eq(:package_not_published)
      expect(stranger.reload.ai_package_id).to be_nil
    end
  end

  describe 'deselection back to the org’s own configuration' do
    it 'clears package, rung and stamps the protocol' do
      select(same_lane_package.id, 'thorough')

      result = described_class.call(organisation: organisation, current_user: user,
                                    params: { ai_package_id: '' })

      expect(result).to be_success
      expect(organisation.reload).to have_attributes(ai_package_id: nil, ai_package_tier_key: nil,
                                                     ai_package_selected_by_id: user.id)
      expect(organisation.ai_package_selected_at).to be_present
    end

    # The way back is judged by the same rule as the way in: it can move the
    # triple just as much, and since P4a it gets the same migration.
    it 'migrates the way back when it would move the triple' do
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      organisation.update!(ai_package: other_lane_package, ai_package_tier_key: 'fast')

      result = nil
      expect do
        result = described_class.call(organisation: organisation, current_user: user,
                                      params: { ai_package_id: nil })
      end.to have_enqueued_job(Embeddings::ReindexOrganisationJob).once

      expect(result).to be_success
      expect(organisation.reload.ai_package_id).to be_nil
    ensure
      ActiveJob::Base.queue_adapter = original
    end
  end

  # Fail-closed, and P4a KEPT the property while inverting what it costs: "cannot
  # prove this is a no-op" and "is a switch" still get the same answer, except the
  # answer is now "rebuild the index" instead of "refuse". Both land on the safe
  # side — the unsafe one is moving the lane without a rebuild — but the price
  # moved from an annoyed customer to a spent quota, which is why the same-lane
  # short-circuit above matters more than it used to.
  it 'starts the migration when the current triple cannot be resolved at all' do
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    openai_standard.update_columns(enabled: false)

    expect { expect(select(same_lane_package.id)).to be_success }
      .to have_enqueued_job(Embeddings::ReindexOrganisationJob).once
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  # The example above leaves ONE side unresolvable. This is the case where NEITHER
  # does — and it is the one P4a changed most, because the write now lands where
  # it used to be refused.
  #
  # What must NOT happen: the customer gets an error for a change that did take
  # place. #start_migration runs after the commit, EnsureSpace cannot resolve a
  # lane whose every credential is disabled, and an unrescued raise there would
  # travel back through BaseActor's error mapping as a failure Result — reporting
  # a rollback that never happened.
  it 'keeps the write and only logs when the new lane cannot be resolved at all' do
    organisation.update!(ai_package: other_lane_package, ai_package_tier_key: 'fast')
    other_lane_package.embedding_credential.update_columns(enabled: false)
    openai_standard.update_columns(enabled: false)
    allow(Rails.logger).to receive(:error)

    result = described_class.call(organisation: organisation, current_user: user,
                                  params: { ai_package_id: '' })

    expect(result).to be_success
    expect(organisation.reload.ai_package_id).to be_nil
    # Loudly, and naming the org: this org's search will not migrate until an
    # operator repairs the credentials, and nothing else reports it.
    expect(Rails.logger).to have_received(:error).with(/could not start the embedding migration/)
  end

  it 'accepts string-keyed params (controller flavour)' do
    result = described_class.call(organisation: organisation, current_user: user,
                                  params: { 'ai_package_id' => same_lane_package.id,
                                            'ai_package_tier_key' => 'thorough' })

    expect(result).to be_success
    expect(organisation.reload.ai_package_tier_key).to eq('thorough')
  end

  # KI-Pakete P3 — the Leistungsstufe as its OWN kind of write (§2, E4).
  #
  # The plan's central claim is that the two axes are independent: the
  # jurisdiction decides the embedding lane, the rung decides nothing but cost.
  # The guard below is where that claim either holds or quietly stops holding,
  # because the embedding refusal is written as a property of the TRIPLE — and a
  # triple that cannot be resolved refuses fail-closed. Applied to a rung change
  # that would mean a customer's cost decision hangs on the health of the search
  # half, which is exactly the coupling §2 forbids.
  describe 'a pure rung change (P3)' do
    # On the 1024-dim package: the org whose triple is FURTHEST from its own
    # columns, so anything triple-shaped in the way would show up here.
    before { organisation.update!(ai_package: other_lane_package, ai_package_tier_key: 'fast') }

    it 'switches the rung without touching the package' do
      result = select(other_lane_package.id, 'thorough')

      expect(result).to be_success
      expect(organisation.reload).to have_attributes(ai_package_id: other_lane_package.id,
                                                     ai_package_tier_key: 'thorough')
    end

    # THE P3 pin. Both sides of the triple comparison are made unresolvable —
    # the exact state that makes every OTHER write in this file refuse — and a
    # rung change still goes through, because it cannot move a lane it has no
    # say over.
    it 'is never blocked as embedding-effective, not even with no resolvable triple' do
      other_lane_package.embedding_credential.update_columns(enabled: false)
      openai_standard.update_columns(enabled: false)

      result = select(other_lane_package.id, 'thorough')

      expect(result).to be_success
      expect(organisation.reload.ai_package_tier_key).to eq('thorough')
    end

    # The guard is not merely bypassed for this package — it is not consulted.
    # Asked as "was the derivation run at all", because a guard that runs and
    # happens to agree today is one credential change away from disagreeing.
    it 'does not even derive the triple' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_triple_for).and_call_original

      select(other_lane_package.id, 'thorough')

      expect(Lalabase::Llm::Factory).not_to have_received(:embedding_triple_for)
    end

    # Same columns as a package change: who moved this org onto the expensive
    # rung is an operating fact of the same kind as who chose the jurisdiction
    # (§7). A rung change that left the protocol untouched would make the trail
    # say the previous person is still responsible for the current cost.
    it 'stamps the protocol like any other choice' do
      organisation.update_columns(ai_package_selected_at: 3.days.ago, ai_package_selected_by_id: nil)
      other_user = create(:user, organisation: organisation)

      described_class.call(organisation: organisation, current_user: other_user,
                           params: { ai_package_id: other_lane_package.id,
                                     ai_package_tier_key: 'thorough' })

      expect(organisation.reload.ai_package_selected_by_id).to eq(other_user.id)
      expect(organisation.ai_package_selected_at).to be_within(5.seconds).of(Time.current)
    end

    # The rung is still judged against the package's own ladder — skipping the
    # embedding guard says nothing about validation.
    it 'still refuses a rung the package does not offer' do
      other_lane_package.tiers.find_by(key: 'thorough').destroy!

      expect(select(other_lane_package.id, 'thorough').code).to eq(:tier_not_offered)
    end

    # The change reaches the ROUTING, not just the column — otherwise the whole
    # feature would be bookkeeping. Asked as "which credential does the factory
    # resolve now", because that is the question the customer's next chat message
    # asks.
    it 'moves the chat lane onto the new rung' do
      select(other_lane_package.id, 'thorough')

      expect(Lalabase::Llm::Factory.curated_chat_credential(organisation.reload))
        .to eq(other_lane_package.tier_for('thorough').chat_credential)
    end

    # THE lost-update guard (review of #410), and P4a made its failure mode worse
    # rather than obsolete. Every judgement in #perform reads
    # @organisation.ai_package_id, and the controller loaded that object before
    # the actor ran — so without the row lock two admins racing produce a real
    # revert: B moves the org to the same-lane package, A's stale object still
    # says other-lane, #rung_change_only? answers true on A's request, and the
    # lane question is SKIPPED. Under P2 that skipped a refusal; under P4a it
    # skips the REINDEX, and the org ends up routing into a vector space nobody
    # ever built — a silently empty search instead of a visible rejection.
    #
    # So the assertion is on the enqueue, not on the resulting column: the write
    # lands either way, and only the missing reindex tells the two apart.
    #
    # Written against a genuinely stale AR object rather than by spying on
    # #lock!, so it pins the OUTCOME: any future locking strategy that prevents
    # the revert keeps this example green, and removing the lock turns it red.
    it 'judges the row it is about to write, not the stale copy it was handed' do
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      stale = Organisation.find(organisation.id)
      Organisation.where(id: organisation.id).update_all(ai_package_id: same_lane_package.id,
                                                         ai_package_tier_key: 'fast')

      expect do
        described_class.call(organisation: stale, current_user: user,
                             params: { ai_package_id: other_lane_package.id,
                                       ai_package_tier_key: 'thorough' })
      end.to have_enqueued_job(Embeddings::ReindexOrganisationJob).once
    ensure
      ActiveJob::Base.queue_adapter = original
    end
  end

  # A rung whose credential an operator edited AFTER the package was saved.
  # AiPackageTier validates the credential on write, so this state cannot be
  # built through the package — it arises later, and only then.
  #
  # Refused rather than accepted-and-broken: Factory#curated_chat_resolution
  # refuses a tier credential that fails ANY of usable_for?(:chat)'s three
  # conditions (enabled, purpose, endpoint) instead of degrading to the provider
  # default (that refusal is the P0 pin). Writing the choice anyway would leave
  # the org on a rung whose every chat message fails — a write that succeeds and
  # breaks the feature, discovered at the next click rather than at the switch.
  describe 'a rung whose credential became unusable after the fact' do
    before { organisation.update!(ai_package: same_lane_package, ai_package_tier_key: 'fast') }

    it 'refuses the switch and leaves the org on its rung' do
      same_lane_package.tiers.find_by(key: 'thorough').chat_credential.update_columns(enabled: false)

      result = select(same_lane_package.id, 'thorough')

      expect(result.code).to eq(:tier_credential_unusable)
      expect(organisation.reload.ai_package_tier_key).to eq('fast')
      # …and the OTHER rung is untouched — without this line the example above
      # would also pass on a fixture that shares one credential between the two,
      # i.e. for a reason that has nothing to do with the rung being asked about.
      expect(same_lane_package.tier_for('fast').chat_credential.reload).to be_usable_for(:chat)
    end

    # THE discriminating probe, and the one the shared fixture made unwritable:
    # the BROKEN rung is the one nobody asked for. Every plausible mis-reading of
    # the guard fails here — judging #default_selection_tier (which is the broken
    # 'fast' row), judging "does any rung of this package still serve", or judging
    # the org's CURRENT rung all refuse, while the correct question ("can the rung
    # in this request serve chat?") lets it through.
    it 'accepts a switch to a healthy rung while the DEFAULT rung is broken' do
      same_lane_package.tier_for('fast').chat_credential.update_columns(enabled: false)

      result = select(same_lane_package.id, 'thorough')

      expect(result).to be_success
      expect(organisation.reload.ai_package_tier_key).to eq('thorough')
    end

    # The same asymmetry from the other side: a switch back ONTO the broken
    # default rung is refused, so the example above is a statement about which
    # rung was asked for and not about 'thorough' being privileged.
    it 'refuses the switch back onto the broken default rung' do
      organisation.update!(ai_package_tier_key: 'thorough')
      same_lane_package.tier_for('fast').chat_credential.update_columns(enabled: false)

      expect(select(same_lane_package.id, 'fast').code).to eq(:tier_credential_unusable)
      expect(organisation.reload.ai_package_tier_key).to eq('thorough')
    end

    # The judgement is usable_for?(:chat), not enabled? alone — pinned on the
    # purpose axis: a credential edited to 'embedding' is still enabled, and an
    # enabled?-only door would wave the switch through into a Factory refusal.
    it 'refuses the same switch when the credential stopped serving the chat lane' do
      same_lane_package.tiers.find_by(key: 'thorough').chat_credential.update_columns(purpose: 'embedding')

      expect(select(same_lane_package.id, 'thorough').code).to eq(:tier_credential_unusable)
    end

    it 'names the rung in the message, so the customer knows which one' do
      same_lane_package.tiers.find_by(key: 'thorough').chat_credential.update_columns(enabled: false)

      expect(select(same_lane_package.id, 'thorough').errors.join(' ')).to include('thorough')
    end

    # The counter-probe: without the disabling the very same switch succeeds, so
    # the refusal above is about the credential and not about the rung.
    it 'accepts the same switch while the credential is enabled' do
      expect(select(same_lane_package.id, 'thorough')).to be_success
      expect(organisation.reload.ai_package_tier_key).to eq('thorough')
    end
  end

  # KI-Pakete P4e (E4): the HISTORY beside the four columns, which only ever hold
  # the LAST choice. §7 wants "EU ist Standard, US die bewusste Abweichung" to be
  # auditable, and that needs every deviation to have left a trace naming the
  # jurisdiction it moved between.
  describe 'the protocol trail' do
    def last_activity
      Activity.order(:created_at).last
    end

    # EVERY other package in this file derives `eu_native`, so no example here moves
    # the jurisdiction — and that is the one movement §7 exists to make auditable.
    # Proven rather than assumed: hard-coding both jurisdiction fields to 'eu_native'
    # left all 46 examples green (P4e review M1).
    #
    # Region and domicile come from the MATRIX rather than a guess: AiPackage
    # validates the declared rung against the pair it derives from the credentials
    # (§3), so a crude mapping could only ever build the two extreme rungs.
    let(:non_eu_package) do
      domicile_eu, region_eu = AiPackage::JURISDICTION_MATRIX.key('non_eu')
      credential = create(:ai_credential, :embedding_only,
                          provider: 'openai', name: 'US embeddings',
                          access_token: 'sk-us-embed-1234567890',
                          region: region_eu ? 'eu' : 'us',
                          company_domicile: domicile_eu ? 'eu' : 'non_eu')
      package = create(:ai_package, embedding_credential: credential,
                                    embedding_model: 'text-embedding-3-small', embedding_dims: 1536,
                                    jurisdiction: 'non_eu', active: false)
      AiPackageTier::KEYS.each_with_index do |key, index|
        package.tiers.create!(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                              position: index, chat_credential: chat_credential_for(key))
      end
      package.update!(active: true)
      package
    end

    # THE example this slice exists for. "EU ist Standard, US die bewusste Abweichung"
    # is only auditable if the deviation left a trace naming BOTH sides — and the
    # fixture has to actually move between them, or the assertion is satisfied by two
    # identical values.
    it 'records both jurisdictions when the choice moves between them' do
      expect(same_lane_package.effective_jurisdiction).to eq('eu_native')
      expect(non_eu_package.effective_jurisdiction).to eq('non_eu')

      select(same_lane_package.id)
      select(non_eu_package.id)

      expect(last_activity.parameters).to include('from_jurisdiction' => 'eu_native',
                                                  'to_jurisdiction' => 'non_eu')
    end

    # The way back, because an audit that only recorded deviations could not show a
    # return to the EU — and `from_jurisdiction` had no assertion anywhere in the repo.
    it 'records the way back out of the third country' do
      select(non_eu_package.id)
      select(same_lane_package.id)

      expect(last_activity.parameters).to include('from_jurisdiction' => 'non_eu',
                                                  'to_jurisdiction' => 'eu_native')
    end

    # Leaving a package for the org's own configuration makes NO jurisdiction claim —
    # whatever it configures applies — so nil is the honest value, not a guess.
    it 'claims no jurisdiction for the way back to the own configuration' do
      select(non_eu_package.id)
      select('')

      expect(last_activity.parameters).to include('from_jurisdiction' => 'non_eu',
                                                  'to_jurisdiction' => nil)
    end

    it 'records the package switch with its jurisdiction and the person' do
      expect { select(same_lane_package.id) }.to change(Activity, :count).by(1)

      expect(last_activity).to have_attributes(actor_id: user.id, trackable: organisation,
                                               action: 'ai_package_selected',
                                               key: 'organisation.ai_package_selected',
                                               secondary: same_lane_package)
      expect(last_activity.parameters).to include(
        'to_package_id' => same_lane_package.id,
        'to_package' => same_lane_package.name,
        'to_jurisdiction' => same_lane_package.effective_jurisdiction
      )
    end

    # ⚠️ THE reason skip_notifications is set. An Activity is not a quiet audit row:
    # after_create_commit reaches OutboxEvent → OutboxConsumeJob → FanoutService
    # (docs/architektur/seiteneffekt_ketten.md), and this key derives no known event
    # type, so Notifications::Constants.derive_event_type falls back to
    # SYSTEM_MESSAGE rather than to nil. Without the flag a package switch would
    # fan a generic system notification, and its e-mails, across the org. (Until
    # 2026-10-02 there was a second flag for two Turbo broadcasts per activity;
    # nothing subscribed to them and they were removed.)
    it 'creates no notification' do
      expect { select(same_lane_package.id) }.not_to change(OutboxEvent, :count)
    end

    # The premise of the example above, measured rather than assumed: the SAME
    # activity without the flags does produce an outbox event. Without this pair,
    # "notifies nobody" would pass just as happily if the chain had never been
    # wired up at all — the declaration-instead-of-mechanism trap.
    it 'would notify without the flag, which is what the flag is for' do
      expect do
        Activity.create!(organisation: organisation, actor: user, trackable: organisation,
                         action: 'ai_package_selected', parameters: {})
      end.to change(OutboxEvent, :count).by(1)
    end

    # The two axes of §2 keep two verbs: only the package switch carries a
    # jurisdiction decision. An audit filing a rung change under the same verb
    # would report a legal decision the customer never made.
    it 'files a pure rung change under its own verb' do
      select(same_lane_package.id)

      expect { select(same_lane_package.id, 'thorough') }.to change(Activity, :count).by(1)
      expect(last_activity).to have_attributes(action: 'ai_tier_selected')
      expect(last_activity.parameters).to include('from_tier_key' => AiPackageTier::DEFAULT_KEY,
                                                  'to_tier_key' => 'thorough')
    end

    # Reachable only by a hand-built POST — every door renders the current package
    # as a disabled state. "Nothing happened" does not belong in an audit trail.
    it 'writes nothing when neither axis moved' do
      select(same_lane_package.id)

      expect { select(same_lane_package.id) }.not_to change(Activity, :count)
    end

    # The FIRST choice, where ai_package_tier_key is still NULL. The rung-change
    # example next door already has the column set to 'fast', so its
    # `from_tier_key => DEFAULT_KEY` assertion reads identically with and without the
    # fallback — removing `.presence || DEFAULT_KEY` left all 46 green (review M5).
    # Blank and DEFAULT_KEY mean the same rung, and the trail should say which rung,
    # not which of two ways of writing it.
    it 'names the default rung when the organisation had none recorded' do
      expect(organisation.ai_package_tier_key).to be_nil

      select(same_lane_package.id)

      expect(last_activity.parameters).to include('from_tier_key' => AiPackageTier::DEFAULT_KEY)
    end

    # A rung key surviving on an org with NO package is data drift, and clearing it is
    # not a customer decision about anything. Without this the entry would render as
    # `von "thorough" auf ""` — the empty pair of quotes the package axis avoids.
    it 'stays silent when no package is involved on either side' do
      organisation.update_columns(ai_package_id: nil, ai_package_tier_key: 'thorough')

      expect { select('') }.not_to change(Activity, :count)
    end

    # acts_as_tenant OVERWRITES the passed `organisation:` from
    # ActsAsTenant.current_tenant in a before_validation on :create — so without
    # #log_choice's with_tenant, this audit row silently lands in whichever mandant
    # happened to be ambient. Every other example here runs with current_tenant ==
    # organisation (the `before` hook), so none of them can see the difference; this
    # one deliberately sets a FOREIGN tenant, which is the only way the guard becomes
    # observable at all.
    #
    # Read through without_tenant, because Activity is itself tenant-scoped: under the
    # foreign tenant the default scope would answer "no rows" and the example would
    # pass by finding nothing.
    it 'writes the audit row into the organisation it is about, not the ambient tenant' do
      ActsAsTenant.current_tenant = create(:organisation)

      select(same_lane_package.id)

      activity = ActsAsTenant.without_tenant { Activity.order(:created_at).last }
      expect(activity.organisation_id).to eq(organisation.id)
    end

    # current_user became mandatory with this slice: Activity#actor is a required
    # belongs_to. Pinned because the failure message names a field the caller never
    # mentioned, and because the write must not commit without its protocol entry.
    it 'refuses the whole write without an audit user' do
      result = described_class.call(organisation: organisation, current_user: nil,
                                    params: { ai_package_id: same_lane_package.id })

      expect(result).not_to be_success
      expect(organisation.reload.ai_package_id).to be_nil
    end

    # The way back. `from_package`/`to_package` are interpolated straight into
    # activities.messages.*, so a nil would render as an empty pair of quotes —
    # the label carries the same wording the catalogue uses instead.
    # ...and it does so in ONE locale regardless of who clicked. A switch performed
    # under an English UI used to write "Own configuration" into a trail a German
    # admin reads (review M2) — the same freezing the jurisdiction field deliberately
    # avoids by storing raw keys.
    it 'names "Eigene Konfiguration" rather than leaving the label blank' do
      select(same_lane_package.id)
      I18n.with_locale(:en) { select('') }

      expect(last_activity.parameters).to include(
        'from_package' => same_lane_package.name,
        'to_package' => I18n.t('views.organisations.ai_settings.packages.custom.title',
                               locale: I18n.default_locale),
        'to_package_id' => nil
      )
      # Renders through the real locale rather than falling into Activity#message's
      # MissingInterpolationArgument rescue — which would silently swallow a
      # parameter the message needs.
      expect(last_activity.message).to include(same_lane_package.name)
    end

    # The operating half of the same decision, and the one field that cannot be
    # reconstructed from the two package rows afterwards.
    it 'records whether the choice also started a paid re-embedding' do
      select(same_lane_package.id)
      expect(last_activity.parameters).to include('embedding_lane_moved' => false)

      select(other_lane_package.id)
      expect(last_activity.parameters).to include('embedding_lane_moved' => true)
    end
  end
end
