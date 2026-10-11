# frozen_string_literal: true

require 'rails_helper'

# R1 of doc/ai_feature_registry_plan.md: the registry answers the feature question,
# and NOTHING about the answer changes. This file is the Definition of Done — without
# it, "verhaltensneutral" is a claim.
#
# The comparison is deliberately against the untouched LOW-LEVEL predicates, never
# against another registry-backed predicate — that would be circular (plan §8):
# ai_enabled? + has_valid_ai_configuration? for the unpinned chat features.
#
# TWO of the three groups have no predecessor left to compare against, for opposite
# reasons, and both are therefore pinned SEMANTICALLY — one expectation per org
# state, spelled out in the table below:
#
# * the embedding lane never had one. That gap IS the §2.3 finding, and
#   has_valid_embedding_configuration? is what closes it.
# * the pinned feature had one until R3 deleted it. The S4 pair
#   (ai_available_pinned? / ai_pinned_elsewhere?) has gone into the reason
#   :pinned_elsewhere, so there is nothing low-level left to hold it against —
#   the registry IS the answer now. Nothing was dropped in the move: the pair
#   distinguished "routes elsewhere" from "no credential", and the `pinned:`
#   column below still does, state by state.
RSpec.describe 'Organisation AI feature availability' do
  # AiCredential.active_for_provider caches for 5 minutes; a leftover key from a
  # neighbouring example would answer for this one.
  before { Rails.cache.clear }

  # No credential anywhere — the honest default for a state that is defined by NOT
  # having one, and it keeps the examples independent of what the test DB happens to
  # contain.
  def stub_no_system_credentials
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
  end

  def stub_system_credential(provider, **attrs)
    credential = build_stubbed(:ai_credential, provider: provider, active: true, enabled: true, **attrs)
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    allow(AiCredential).to receive(:active_for_provider).with(provider).and_return(credential)
    credential
  end

  # ── the five org states of the DoD matrix ────────────────────────────────────
  # Each builder returns a FRESH org: availability memoises per instance, so a state
  # must never be a mutated twin of another.

  def state_without_opt_in
    stub_no_system_credentials
    create(:organisation, :ai_disabled, ai_access_token: 'sk-org-own-1234567890abcdef')
  end

  def state_opted_in_without_credential
    stub_no_system_credentials
    create(:organisation, ai_enabled: true, ai_provider: 'openai')
  end

  # BOTH lanes BYOK — the org that needs nothing from us. The two token columns are
  # independent, which is exactly why the state has to set both to be "configured".
  def state_byok
    stub_no_system_credentials
    create(:organisation, ai_enabled: true, ai_provider: 'openai',
                          ai_access_token: 'sk-org-own-1234567890abcdef',
                          embedding_access_token: 'sk-org-own-embed-1234567890')
  end

  def state_system_credential
    stub_system_credential('openai')
    create(:organisation, ai_enabled: true, ai_provider: 'openai')
  end

  # A long-lived org carrying a provider the Factory cannot build. Written with
  # update_columns because the inclusion validations reject the value today — which
  # is the point: this state exists only as legacy data, and the gate still has to
  # answer for it instead of offering a button that raises at the seam.
  def state_legacy_provider
    stub_no_system_credentials
    org = create(:organisation, ai_enabled: true, ai_provider: 'openai')
    org.update_columns(ai_provider: 'cohere', embedding_provider: 'cohere')
    org.reload
  end

  # ── the pre-registry formulas (the "ALT" side of the comparison) ─────────────

  # Exactly what every unpinned chat gate computed before R1 (spelled ai_enabled? &&
  # has_valid_ai_configuration?(chat_provider_name) then, and reachable through the
  # ai_available_for_chat? facade R2 deleted), written out here so the comparison
  # cannot become a tautology.
  def legacy_chat_availability(org)
    org.ai_enabled? && !!org.has_valid_ai_configuration?(Lalabase::Llm::Factory.chat_provider_name(org))
  end

  # The 12 entries, grouped by how their answer is VERIFIED — the grouping is the
  # whole argument of this file, so it is spelled out rather than derived from the
  # registry (deriving it would make the spec agree with the table by construction).
  def unpinned_chat_features
    %i[chat document_summary ticket_summary ask_ai_post meeting_participant_detection
       meeting_summary meeting_analysis meeting_ticket_suggestions]
  end

  def embedding_features
    %i[content_indexing semantic_search]
  end

  # The pin lives in the registry row since R3; naming the literal here keeps this
  # side of the comparison from asking the registry what the registry just said.
  def pinned_provider
    ::AiCredential::PROVIDER_OPENAI
  end

  # ── the matrix: 12 features × 5 org states ──────────────────────────────────
  #
  # `pinned:` is the ONE column whose answers are not derivable from the others, and
  # the 'cohere' row is why it earns its place: that org routes to a provider that is
  # neither the pin nor implemented, so it must be told :pinned_elsewhere. Swap the
  # two lines in FeatureRegistry#chat_failure and exactly this row turns
  # :no_credential — the measured single example that catches the order.
  [
    { label: 'kein Opt-in', builder: :state_without_opt_in,
      embedding: { available: false, reason: :ai_disabled, lane: nil },
      pinned: { available: false, reason: :ai_disabled } },
    { label: 'Opt-in ohne Credential', builder: :state_opted_in_without_credential,
      embedding: { available: false, reason: :no_credential, lane: :embedding },
      pinned: { available: false, reason: :no_credential } },
    { label: 'BYOK (beide Lanes)', builder: :state_byok,
      embedding: { available: true, reason: nil, lane: nil },
      pinned: { available: true, reason: nil } },
    { label: 'System-Credential', builder: :state_system_credential,
      embedding: { available: true, reason: nil, lane: nil },
      pinned: { available: true, reason: nil } },
    { label: 'Legacy-Provider (cohere)', builder: :state_legacy_provider,
      embedding: { available: false, reason: :unsupported_provider, lane: :embedding },
      pinned: { available: false, reason: :pinned_elsewhere } }
  ].each do |state|
    context "org state: #{state[:label]}" do
      let(:org) { send(state[:builder]) }

      it 'answers every unpinned chat feature exactly like the pre-registry formula' do
        expected = legacy_chat_availability(org)

        unpinned_chat_features.each do |key|
          expect(org.ai_available_for?(key).available?).to be(expected), "#{key} diverged"
        end
      end

      it 'answers the pinned feature by the pin\'s own semantics' do
        availability = org.ai_available_for?(:customer_description)

        expect(availability.available?).to be(state[:pinned][:available])
        # The REASON is the half that used to need a second predicate: only an org
        # routing elsewhere gets the provider explanation. Saying "this needs OpenAI,
        # you use OpenAI" to an org whose credential is simply missing would send it
        # looking in the wrong place.
        expect(availability.reason).to eq(state[:pinned][:reason])
        expect(availability.required_provider).to eq(pinned_provider) unless availability.reason == :ai_disabled
      end

      it 'answers the embedding features by the lane\'s own semantics' do
        embedding_features.each do |key|
          availability = org.ai_available_for?(key)

          expect(availability.available?).to be(state[:embedding][:available]), "#{key} diverged"
          expect(availability.reason).to eq(state[:embedding][:reason]), "#{key} reason diverged"
          expect(availability.lane).to eq(state[:embedding][:lane]), "#{key} lane diverged"
        end
      end

      it 'answers the two-lane feature as the AND over both lanes' do
        both_lanes = legacy_chat_availability(org) && state[:embedding][:available]

        expect(org.ai_available_for?(:repository_indexing).available?).to be(both_lanes)
      end
    end
  end

  # R2 DISSOLVED the 'ai_available_for_chat? is answered BY the registry (E5)'
  # describe that stood here: E5 said "two names, one truth", and there is only one
  # name left. Neither half of it was dropped, both moved to where they still bite:
  #
  # * "the registry's answer WINS" only means something at a REAL call site now, so
  #   it moved to spec/requests/organisations/meetings_spec.rb ('each AI surface asks
  #   its own feature key'), same stubbing technique, aimed at a controller and three
  #   partials instead of at a facade.
  # * "there is only ONE resolution" is the memoisation block at the bottom of this
  #   file — with the facade gone, resolving once per instance IS the whole claim.
  #
  # Worth recording why the original was written at all: E5 was the one R1 claim that
  # nothing measured. With the facade reverted to its pre-R1 formula, this file,
  # organisation_spec.rb, all of spec/services/lalabase/llm and both meetings request
  # specs stayed green — 1008 examples, 0 failures.

  # The pin question is asked BEFORE the credential question, and that ORDER is the
  # decision — not an implementation detail. Swapping the two lines leaves every
  # boolean identical and changes only the REASON, so the only org that can catch it
  # is one that fails both halves at once: it routes elsewhere AND has no usable
  # credential for the pin. Measured: with the lines swapped, the matrix above loses
  # exactly one example — the update_columns-only 'cohere' row. This is the same
  # state in its ordinary shape, the one a real customer is in.
  describe 'the pinned feature asks the pin question first' do
    it 'explains "routes elsewhere", not "no credential", when both are true' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'anthropic',
                                  ai_access_token: "sk-ant-#{'a' * 95}")

      availability = org.ai_available_for?(:customer_description)

      expect(availability).not_to be_available
      # The wrong order answers :no_credential here and sends an admin with a
      # perfectly good Anthropic setup hunting for a credential they do not need.
      expect(availability.reason).to eq(:pinned_elsewhere)
      expect(availability.required_provider).to eq(pinned_provider)
    end
  end

  # The one state the matrix cannot express, because a system credential is not one
  # thing: a chat-only credential is a perfectly good CHAT configuration and no
  # embedding configuration at all. Nothing in has_valid_ai_configuration? can see
  # the difference — this is the §2.3 gap in its purest form.
  it 'refuses the embedding lane on a chat-only system credential' do
    stub_system_credential('openai', purpose: 'chat', embedding_cost_per_1m_cents: nil)
    org = create(:organisation, ai_enabled: true, ai_provider: 'openai')

    expect(org.ai_available_for?(:chat)).to be_available
    expect(org.ai_available_for?(:semantic_search)).not_to be_available
    expect(org.ai_available_for?(:semantic_search).reason).to eq(:no_credential)
  end

  describe 'the reasons carry what a surface needs to explain them' do
    it 'names no lane and no provider for a missing opt-in — that org has one problem' do
      availability = state_without_opt_in.ai_available_for?(:chat)

      expect(availability.reason).to eq(:ai_disabled)
      expect(availability.lane).to be_nil
      expect(availability.required_provider).to be_nil
    end

    it 'names the provider a missing credential is missing FOR' do
      org = state_opted_in_without_credential
      org.update!(ai_provider: 'google')

      expect(org.ai_available_for?(:chat).required_provider).to eq('google')
    end

    it 'raises on an unknown feature key instead of answering "not available"' do
      expect { state_byok.ai_available_for?(:no_such_feature) }.to raise_error(KeyError)
    end
  end

  # Plan §7.1: the two lanes must not merge. These two examples fail the moment an
  # embedding question is answered out of the chat columns (which is what
  # meetings/_search_status.html.erb does today) or vice versa.
  describe 'lane separation' do
    it 'offers chat but not search when only the chat lane is configured' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                  ai_access_token: 'sk-org-own-1234567890abcdef')

      expect(org.ai_available_for?(:chat)).to be_available
      search = org.ai_available_for?(:semantic_search)
      expect(search).not_to be_available
      expect(search.reason).to eq(:no_credential)
      expect(search.lane).to eq(:embedding)
    end

    it 'offers search but not chat when only the embedding lane is configured' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                  embedding_access_token: 'sk-org-own-embed-1234567890')

      expect(org.ai_available_for?(:semantic_search)).to be_available
      chat = org.ai_available_for?(:chat)
      expect(chat).not_to be_available
      expect(chat.reason).to eq(:no_credential)
      expect(chat.lane).to eq(:chat)
    end

    it 'fails a two-lane feature on the lane that is actually missing' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                  ai_access_token: 'sk-org-own-1234567890abcdef')

      availability = org.ai_available_for?(:repository_indexing)

      expect(availability).not_to be_available
      expect(availability.reason).to eq(:no_credential)
      expect(availability.lane).to eq(:embedding)
    end
  end

  # Five org states are five POINTS, and the predicate has more branches than that.
  # Each example here is a branch of the new embedding predicate that no other
  # example in this file executes.
  describe 'states the five-state matrix does not reach' do
    # "Deactivated" is not "absent": active_for_provider still FINDS the row, and
    # only the enabled? check keeps the gate shut. The matrix stubs the lookup to
    # nil, so it never reaches that check on either lane.
    it 'treats a deactivated system credential as no configuration, on both lanes' do
      stub_system_credential('openai', enabled: false)
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai')

      expect(org.ai_available_for?(:chat)).not_to be_available
      expect(org.ai_available_for?(:chat).reason).to eq(:no_credential)
      expect(org.ai_available_for?(:semantic_search)).not_to be_available
      expect(org.ai_available_for?(:semantic_search).reason).to eq(:no_credential)
    end

    # The #391 gate case, mirrored onto the embedding lane.
    # Factory#resolve_embedding_credentials takes the endpoint from
    # additional_config['uri_base'] and the model from default_model — BOTH, and
    # neither has a constant fallback, so a credential missing either one is a
    # button that dies at the first embed. Each half is asserted separately
    # because an && that lost one half would still pass a single combined case.
    it 'refuses an openai_compatible system credential missing its endpoint or its model' do
      org = create(:organisation, ai_enabled: true, embedding_provider: 'openai_compatible')

      stub_system_credential('openai_compatible', additional_config: { 'uri_base' => 'https://eu.example/v1' },
                                                  default_model: nil)
      expect(org.has_valid_embedding_configuration?('openai_compatible')).to be(false)

      stub_system_credential('openai_compatible', additional_config: {}, default_model: 'bge-m3')
      expect(org.has_valid_embedding_configuration?('openai_compatible')).to be(false)

      stub_system_credential('openai_compatible', additional_config: { 'uri_base' => 'https://eu.example/v1' },
                                                  default_model: 'bge-m3')
      expect(org.has_valid_embedding_configuration?('openai_compatible')).to be(true)
    end

    # The BYOK twin of the same question, and the reason the branch is written at
    # all: new rows are covered by the presence validation on
    # embedding_api_base/embedding_model, so this can only ever fire for rows
    # written before it — which is precisely why nothing else executes it.
    it 'refuses a legacy openai_compatible BYOK row whose base URL or model went missing' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, embedding_provider: 'openai_compatible',
                                  embedding_access_token: 'sk-own-compatible-1234567890',
                                  embedding_api_base: 'https://eu.example/v1', embedding_model: 'bge-m3')
      expect(org.has_valid_embedding_configuration?('openai_compatible')).to be(true)

      org.update_columns(embedding_model: nil)
      expect(org.has_valid_embedding_configuration?('openai_compatible')).to be(false)

      org.update_columns(embedding_model: 'bge-m3', embedding_api_base: nil)
      expect(org.has_valid_embedding_configuration?('openai_compatible')).to be(false)
    end

    # A legacy provider on ONE column only. The lanes read different columns, so
    # "unsupported" has to stay on the lane that carries it: an org that can still
    # chat must not lose its chat because its embedding column went stale.
    it 'keeps an unsupported provider on the lane that actually carries it' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                  ai_access_token: 'sk-org-own-1234567890abcdef',
                                  embedding_access_token: 'sk-org-own-embed-1234567890')
      org.update_columns(embedding_provider: 'cohere')

      expect(org.ai_available_for?(:chat)).to be_available
      search = org.ai_available_for?(:semantic_search)
      expect(search.reason).to eq(:unsupported_provider)
      expect(search.lane).to eq(:embedding)
      expect(search.required_provider).to eq('cohere')
    end

    # The mixed tier the matrix collapses: BYOK on chat, system credential on
    # embeddings. Each lane must resolve on its OWN tier — a shared has_own_*
    # check would make the chat token terminal for the embedding lane too and
    # answer "no configuration" for an org that is perfectly well configured.
    it 'resolves each lane on its own credential tier' do
      stub_system_credential('openai')
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                  ai_access_token: 'sk-org-own-1234567890abcdef')

      expect(org.ai_available_for?(:chat)).to be_available
      expect(org.ai_available_for?(:semantic_search)).to be_available
      expect(org.ai_available_for?(:repository_indexing)).to be_available
    end
  end

  # The verified hard boundary (plan §2.5): AnthropicProvider inherits
  # supports_embeddings? = false and does not override it.
  describe 'the Anthropic case' do
    let(:org) do
      stub_no_system_credentials
      create(:organisation, ai_enabled: true, ai_provider: 'anthropic',
                            ai_access_token: "sk-ant-#{'a' * 95}")
    end

    it 'serves every chat feature' do
      unpinned_chat_features.each do |key|
        expect(org.ai_available_for?(key)).to be_available, "#{key} unexpectedly unavailable"
      end
    end

    # Reachable ONLY as legacy data: the embedding_provider inclusion validation
    # rejects a chat-only provider today, so update_columns is how this row comes to
    # exist at all. Worth pinning anyway — the reason exists for exactly these rows,
    # and "unreachable" is a property of today's validation, not of the data.
    it 'reports incapability — not a missing credential — for every embedding feature' do
      org.update_columns(embedding_provider: 'anthropic')

      # One instance answers all three: the memo is per FEATURE key, and nothing was
      # resolved on this org before the column changed.
      (embedding_features + [:repository_indexing]).each do |key|
        availability = org.ai_available_for?(key)

        expect(availability).not_to be_available, "#{key} unexpectedly available"
        expect(availability.reason).to eq(:provider_incapable), "#{key} reason diverged"
        expect(availability.lane).to eq(:embedding)
      end
    end
  end

  # Plan §5.3 point 1 in test form: gate and route read the SAME row, so they cannot
  # disagree. Both directions of the same table.
  describe 'gate and route are paired' do
    it 'withholds the pinned feature from an org routing elsewhere — and still routes it to the pin' do
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                                  ai_access_token: 'sk-mistral-own-token-1234567890',
                                  ai_api_base: 'https://api.mistral.ai/v1',
                                  preferred_chat_model: 'mistral-small-latest')
      create(:ai_credential, :active, provider: 'openai')
      allow(Lalabase::Llm::Factory).to receive(:build).and_call_original

      availability = org.ai_available_for?(:customer_description)
      expect(availability).not_to be_available
      expect(availability.reason).to eq(:pinned_elsewhere)
      expect(availability.required_provider).to eq(pinned_provider)

      # THE point: the gate closing does not move the data. A usable OpenAI credential
      # exists, so the route succeeds — and it goes to OpenAI, not to the org's
      # Mistral endpoint. Gate and route say the same thing about the same row.
      expect(Lalabase::Llm::Factory.for_feature(:customer_description, org))
        .to be_a(Lalabase::Llm::OpenAiProvider)
      expect(Lalabase::Llm::Factory).to have_received(:build)
        .with(provider_name: pinned_provider, organisation: org)
    end

    it 'routes an unpinned feature to the org\'s own provider' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'anthropic',
                                  ai_access_token: "sk-ant-#{'a' * 95}")

      expect(org.ai_available_for?(:chat)).to be_available
      expect(Lalabase::Llm::Factory.for_feature(:chat, org)).to be_a(Lalabase::Llm::AnthropicProvider)
    end

    it 'routes an embedding feature through the embedding lane' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'anthropic',
                                  ai_access_token: "sk-ant-#{'a' * 95}",
                                  embedding_access_token: 'sk-org-own-embed-1234567890')

      expect(Lalabase::Llm::Factory.for_feature(:semantic_search, org, space: :active))
        .to be_a(Lalabase::Llm::OpenAiProvider)
    end

    # The ArgumentError examples below prove that a lane MUST be named. This proves
    # the name is then USED: the two lanes of the one two-lane feature land on two
    # different providers out of the same registry row. Without it, effective_lane
    # could ignore its argument entirely and only the raises would notice.
    it 'routes each lane of the two-lane feature to that lane\'s own provider' do
      stub_no_system_credentials
      org = create(:organisation, ai_enabled: true, ai_provider: 'anthropic',
                                  ai_access_token: "sk-ant-#{'a' * 95}",
                                  embedding_access_token: 'sk-org-own-embed-1234567890')

      expect(Lalabase::Llm::Factory.for_feature(:repository_indexing, org, lane: :chat))
        .to be_a(Lalabase::Llm::AnthropicProvider)
      expect(Lalabase::Llm::Factory.for_feature(:repository_indexing, org, lane: :embedding, space: :configured))
        .to be_a(Lalabase::Llm::OpenAiProvider)
    end

    # Both mandatory arguments exist for the same reason: every plausible default has
    # a SILENT failure mode (the wrong vector space, or a lane that routes to a
    # different provider than the caller assumed). An ArgumentError has none.
    it 'refuses to guess the vector space' do
      expect { Lalabase::Llm::Factory.for_feature(:semantic_search, state_byok) }
        .to raise_error(ArgumentError, /space/)
    end

    it 'refuses to guess the lane of a two-lane feature' do
      expect { Lalabase::Llm::Factory.for_feature(:repository_indexing, state_byok) }
        .to raise_error(ArgumentError, /lane/)
    end

    it 'refuses a lane the feature does not declare' do
      expect { Lalabase::Llm::Factory.for_feature(:chat, state_byok, lane: :embedding) }
        .to raise_error(ArgumentError, /embedding/)
    end

    # Adversarial review B4: a surplus space: on a chat route was swallowed
    # silently — the caller believed it addressed a vector space while routing
    # chat, the exact silent-failure class the kwarg exists to prevent.
    it 'refuses a surplus space: on a chat-lane route' do
      expect { Lalabase::Llm::Factory.for_feature(:chat, state_byok, space: :active) }
        .to raise_error(ArgumentError, /space/)
    end
  end

  # Plan §7.3: the availability service is ADVISORY. The fail-closed gates at the seam
  # do not care what it said a moment ago — which is also what makes per-instance
  # memoisation safe.
  describe 'fail-closed layering' do
    it 'still refuses at the seam when the opt-in is withdrawn after the gate said yes' do
      org = state_byok
      expect(org.ai_available_for?(:chat)).to be_available

      org.update!(ai_enabled: false)

      expect { Lalabase::Llm::Factory.for_feature(:chat, org) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
      # The memoised answer is deliberately stale — the seam is the guarantee, not the
      # gate (factory.rb ensure_ai_enabled! "this gate may not [be removed]").
      expect(org.ai_available_for?(:chat)).to be_available
    end

    # The opt-in gate has to sit on every door for_feature opens, and for_feature
    # opens three: for_chat, for_embeddings and — for the one pinned entry —
    # Factory.build directly. Only the first was covered; a pin must not be a way
    # around the GDPR opt-in.
    it 'refuses the PINNED route too, which reaches the seam through Factory.build' do
      org = create(:organisation, ai_enabled: false, ai_provider: 'openai')
      create(:ai_credential, :active, provider: 'openai')

      expect { Lalabase::Llm::Factory.for_feature(:customer_description, org) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'refuses the EMBEDDING route when the opt-in is missing' do
      org = create(:organisation, ai_enabled: false,
                                  embedding_access_token: 'sk-org-own-embed-1234567890')

      expect { Lalabase::Llm::Factory.for_feature(:semantic_search, org, space: :active) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'keeps the button and raises at the seam when the quota is exhausted (E4)' do
      org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                  ai_quota_credits_override: 10, ai_quota_buffer_override: 5)
      credential = create(:ai_credential, :active, provider: 'openai', included_in_quota: true)
      AiUsage.create!(organisation: org, provider: 'openai', ai_credential: credential,
                      credits_used: 20, used_at: Time.current)

      # Quota is NOT an availability reason: it is dynamic, it has its own UI, and
      # hiding the button would replace "button + quota banner" with a mystery.
      expect(org.ai_available_for?(:chat)).to be_available
      expect { Lalabase::Llm::Factory.for_feature(:chat, org) }
        .to raise_error(Lalabase::Llm::QuotaExceededError)
    end
  end

  # Plan §7.6 / the #368 lesson: a gate this convenient ends up in row partials, and
  # each resolution can hit AiCredential.active_for_provider (a cache read, in
  # production a Solid-Cache SELECT). What is cached is the ANSWER, not the resolver —
  # Pundit memoised the policy INSTANCE and the N+1 survived a green guard spec.
  describe 'memoisation' do
    it 'resolves a feature once per instance' do
      org = state_byok
      allow(org).to receive(:has_valid_ai_configuration?).and_call_original

      3.times { org.ai_available_for?(:chat) }

      expect(org).to have_received(:has_valid_ai_configuration?).once
    end

    it 'memoises per feature, not one answer for all' do
      org = state_byok

      expect(org.ai_available_for?(:chat)).to be_available
      expect(org.ai_available_for?(:customer_description)).to be_available
      expect(org.ai_available_for?(:chat).lane).to be_nil
    end

    it 'lives exactly as long as the object — a reloaded record answers freshly' do
      org = state_byok
      expect(org.ai_available_for?(:chat)).to be_available

      Organisation.where(id: org.id).update_all(ai_enabled: false)

      expect(org.ai_available_for?(:chat)).to be_available
      expect(Organisation.find(org.id).ai_available_for?(:chat)).not_to be_available
    end
  end

  # The predicate the registry could not be built without (§2.3). Its chat twin is
  # untouched by R1; these examples pin what makes the embedding one DIFFERENT.
  describe '#has_valid_embedding_configuration?' do
    let(:org) { create(:organisation, ai_enabled: true) }

    it 'reads the embedding columns, not the chat ones' do
      stub_no_system_credentials
      org.update!(ai_access_token: 'sk-org-own-1234567890abcdef')

      expect(org.has_valid_ai_configuration?('openai')).to be(true)
      expect(org.has_valid_embedding_configuration?('openai')).to be(false)
    end

    it 'treats BYOK as terminal — no silent fallback to a system credential' do
      stub_system_credential('openai')
      org.update!(embedding_access_token: 'broken-token')

      expect(org.has_valid_embedding_configuration?('openai')).to be(false)
    end

    it 'requires an embedding purpose on the system credential' do
      stub_system_credential('openai', purpose: 'chat', embedding_cost_per_1m_cents: nil)
      expect(org.has_valid_embedding_configuration?('openai')).to be(false)

      stub_system_credential('openai', purpose: 'embedding')
      expect(org.has_valid_embedding_configuration?('openai')).to be(true)
    end

    it 'rejects a provider that cannot do embeddings at all' do
      stub_system_credential('anthropic')
      expect(org.has_valid_embedding_configuration?('anthropic')).to be(false)
    end

    it 'rejects a plain API key for google — a Vertex embedding needs the service account too' do
      org.update_columns(embedding_provider: 'google', embedding_access_token: 'AIzaSyDummyKeyLongEnough12345')
      expect(org.has_valid_embedding_configuration?('google')).to be(false)

      # INHERITED GAP, pinned deliberately (adversarial review B1): the JSON
      # passes this gate, yet the factory cannot BUILD a BYOK google provider —
      # org columns carry no additional_config (project_id/location), so the call
      # dies at the provider guard. The chat-lane twin has the identical gap at
      # HEAD; R1 mirrors behaviour, it does not decide it. The honest fix
      # (reject google BYOK in BOTH lane predicates until org columns can carry
      # the config) is a behaviour change and tracked as a follow-up — it must
      # not ride in on a neutrality-guaranteed slice.
      org.update!(embedding_access_token: { type: 'service_account', project_id: 'lala-eu',
                                            private_key: 'x', client_email: 'v@lala.iam' }.to_json)
      expect(org.has_valid_embedding_configuration?('google')).to be(true)
    end

    it 'never raises when the credential lookup itself fails — a view gate must not 500' do
      allow(AiCredential).to receive(:active_for_provider).and_raise(StandardError, 'cache down')

      expect(org.has_valid_embedding_configuration?('openai')).to be(false)
    end
  end
end

# The Definition of Done of E7 (doc/ki_pakete_plan.md): the packages slice was
# sequenced BEHIND the registry so that P2 would not have to teach the registry
# anything. This file is where that claim is measured — the registry has to answer
# for a curated org WITHOUT knowing packages exist.
#
# The mechanism is one sentence: the registry states its requirements against what
# the FACTORY resolves for an org (feature_registry.rb header, plan E7), and P2
# changed only the innards of that resolution.
RSpec.describe 'AI feature availability follows the package (KI-Pakete P2, E7)' do
  before { Rails.cache.clear }

  after { ActsAsTenant.current_tenant = nil }

  # The Vertex-standard org of the plan's example: everything about its own
  # columns says google, and nothing about them says openai_compatible.
  let(:organisation) do
    org = create(:organisation, ai_enabled: true, ai_provider: 'google', embedding_provider: 'google')
    ActsAsTenant.current_tenant = org
    org
  end

  let(:eu_chat) do
    create(:ai_credential, :openai_compatible, :eu_company, name: 'Mistral FR chat',
                                                            access_token: 'mistral-chat-token-123456')
  end

  let(:eu_embedding) do
    create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
           name: 'Mistral FR embed', access_token: 'mistral-embed-token-123')
  end

  def eu_package
    package = create(:ai_package, embedding_credential: eu_embedding, embedding_model: 'mistral-embed',
                                  embedding_dims: 1024)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers.create!(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                            position: index, chat_credential: eu_chat)
    end
    package.update!(active: true)
    package
  end

  # THE DoD. No credential exists for the org's own provider, so an answer of
  # "available" can only have come through the package.
  it 'offers a chat feature through the package credential alone' do
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    organisation.update!(ai_package: eu_package, ai_package_tier_key: 'fast')

    availability = organisation.ai_available_for?(:chat)

    expect(availability).to be_available
    expect(availability.required_provider).to eq('openai_compatible')
  end

  it 'offers an embedding feature through the package credential alone' do
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    organisation.update!(ai_package: eu_package)

    expect(organisation.ai_available_for?(:semantic_search)).to be_available
  end

  # The other direction, so "available" is not simply this block's constant:
  # a package whose credential stops working turns the SAME feature off.
  it 'withdraws the feature when the package credential is disabled' do
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    package = eu_package
    organisation.update!(ai_package: package)
    eu_chat.update_columns(enabled: false)

    expect(Organisation.find(organisation.id).ai_available_for?(:chat)).not_to be_available
  end

  # An openai_compatible credential without an endpoint is a hard runtime raise in
  # the provider, and the gate has to predict it — otherwise the surface offers a
  # search that 500s. The model half of that pair cannot go missing on a package
  # (embedding_model is presence-validated for curated), so the endpoint is the
  # only thing left to check.
  it 'withdraws the embedding feature when the package endpoint is missing' do
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    package = eu_package
    organisation.update!(ai_package: package)
    eu_embedding.update_columns(api_base: nil, additional_config: nil)

    expect(Organisation.find(organisation.id).ai_available_for?(:semantic_search)).not_to be_available
  end

  # The pin is a statement about the ROUTE, not about the org's configuration, so
  # a curated org routing elsewhere must hear :pinned_elsewhere — the reason that
  # names an actionable difference instead of a missing credential.
  it 'still reports a pinned feature as pinned elsewhere' do
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    organisation.update!(ai_package: eu_package)

    expect(organisation.ai_available_for?(:customer_description).reason).to eq(:pinned_elsewhere)
  end

  # The PURPOSE half of "gate and routing judge the same call the same way", on
  # the package path. Factory#curated_embedding_resolution raises on a chat-only
  # credential (pinned in factory_spec); without the twin here the surface would
  # offer a search that raises at the seam — the exact asymmetry P2 removed on the
  # custom path, re-introduced on the curated one.
  #
  # update_columns because the package's own validation refuses a chat-only
  # embedding slot: this state only arises the way it does in production, by the
  # purpose changing under a live package.
  it 'withdraws the embedding feature when the package credential stops allowing embeddings' do
    allow(AiCredential).to receive(:active_for_provider).and_return(nil)
    organisation.update!(ai_package: eu_package)
    eu_embedding.update_columns(purpose: 'chat', embedding_cost_per_1m_cents: nil)

    expect(Organisation.find(organisation.id).ai_available_for?(:semantic_search)).not_to be_available
  end

  # The neutrality claim of E1-C, measured rather than reasoned: `ai_package_id
  # IS NULL` must resolve exactly like `kind: custom`, which means the mere
  # EXISTENCE of published packages may not reach an org that picked none.
  #
  # Worth its own example because the plausible next feature — "a default package
  # every new org starts on" — is one `AiPackage.published.first` away from
  # turning every Bestands-Org's routing into someone else's decision, and
  # nothing else in the suite would notice.
  it 'leaves an organisation without a package untouched by the catalogue' do
    package = eu_package
    organisation.update!(ai_package: nil, ai_provider: 'google', embedding_provider: 'google')

    expect(package).to be_persisted
    expect(Lalabase::Llm::Factory.chat_provider_name(organisation)).to eq('google')
    expect(Lalabase::Llm::Factory.embedding_provider_name(organisation)).to eq('google')
    expect(Lalabase::Llm::Factory.curated_chat_credential(organisation)).to be_nil
    expect(Lalabase::Llm::Factory.curated_embedding_credential(organisation)).to be_nil
  end

  # KI-Pakete P3: the rung is part of "which credential", so it has to travel
  # with the GATE question as well as with the routing one.
  #
  # Without this the flag would introduce a new instance of exactly the drift the
  # registry was built to end (plan §1.2, three incidents in one week), one
  # package version later: the gate would judge the rung the org picked while the
  # request ran on the cheapest one. Both halves are asserted in every example —
  # a gate that agrees with itself proves nothing.
  describe 'the utility rung is gated as it is routed (P3)' do
    let(:eu_chat_thorough) do
      create(:ai_credential, :openai_compatible, :eu_company, name: 'Mistral FR large',
                                                              default_model: 'mistral-large-latest',
                                                              access_token: 'mistral-large-token-1234')
    end

    # eu_package puts eu_chat on BOTH rungs; the thorough one moves to its own
    # credential so the two rungs can fail independently.
    let(:two_rung_package) do
      package = eu_package
      package.tiers.find_by(key: 'thorough').update!(chat_credential: eu_chat_thorough)
      package.tiers.reload
      package
    end

    before do
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      organisation.update!(ai_package: two_rung_package, ai_package_tier_key: 'thorough')
    end

    it 'withdraws a utility feature when the FAST rung breaks, and keeps the org rung' do
      eu_chat.update_columns(enabled: false)
      org = Organisation.find(organisation.id)

      expect(org.ai_available_for?(:ticket_summary)).not_to be_available
      expect(org.ai_available_for?(:chat)).to be_available
      # …and the routing draws the same line.
      expect { Lalabase::Llm::Factory.for_feature(:ticket_summary, org) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError)
      expect(Lalabase::Llm::Factory.for_feature(:chat, org).api_key).to eq('mistral-large-token-1234')
    end

    it 'keeps a utility feature when the ORG rung breaks — it does not run on it' do
      eu_chat_thorough.update_columns(enabled: false)
      org = Organisation.find(organisation.id)

      expect(org.ai_available_for?(:ticket_summary)).to be_available
      expect(org.ai_available_for?(:chat)).not_to be_available
      expect(Lalabase::Llm::Factory.for_feature(:ticket_summary, org).api_key)
        .to eq('mistral-chat-token-123456')
      expect { Lalabase::Llm::Factory.for_feature(:chat, org) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError)
    end
  end

  # The structural half of E7: the behaviour above must not have been bought with
  # a package branch inside the registry. A guard rather than a comment, because
  # "we did not have to touch it" is exactly the kind of claim that quietly stops
  # being true on the next slice.
  it 'needs no package knowledge in the registry itself' do
    source = File.read(Rails.root.join('app/services/lalabase/llm/feature_registry.rb'))

    expect(source).not_to match(/ai_package|AiPackage|curated/i)
  end
end
