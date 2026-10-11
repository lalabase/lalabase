# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Llm::Factory do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe '.for_chat' do
    it 'returns OpenAiProvider when org.ai_provider is openai' do
      organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-test')
      provider = described_class.for_chat(organisation)
      expect(provider).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    it 'returns AnthropicProvider when org.ai_provider is anthropic' do
      organisation.update!(ai_provider: 'anthropic', ai_access_token: 'sk-ant-' + 'a' * 95)
      provider = described_class.for_chat(organisation)
      expect(provider).to be_a(Lalabase::Llm::AnthropicProvider)
    end

    it 'defaults to openai when ai_provider is blank' do
      organisation.update!(ai_provider: nil, ai_access_token: 'sk-test')
      provider = described_class.for_chat(organisation)
      expect(provider).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    it 'defaults to openai when ai_provider is an empty string (presence? boundary)' do
      organisation.update!(ai_provider: '', ai_access_token: 'sk-test')
      expect(described_class.for_chat(organisation)).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    # NOTE: Organisation validates ai_provider against its own whitelist before
    # data reaches the Factory. These tests bypass that validation to prove the
    # Factory's *own* defensive normalisation works — defense in depth.
    # NB: org#has_own_ai_credentials? is case-sensitive — so when ai_provider is
    # mixed-case we DON'T get BYOK match and the Factory falls through to system
    # credentials. The class-resolution path is what we're testing here.
    it 'normalises ai_provider case-insensitively (`OPENAI` → openai)' do
      organisation.assign_attributes(ai_provider: 'OPENAI', ai_access_token: 'sk-test')
      organisation.save!(validate: false)
      allow(AiCredential).to receive(:active_for_provider).with('openai')
                                                          .and_return(build_stubbed(:ai_credential, provider: 'openai', enabled: true, access_token: 'k'))
      expect(described_class.for_chat(organisation)).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    it 'normalises ai_provider case-insensitively (`Anthropic` → anthropic)' do
      organisation.assign_attributes(ai_provider: 'Anthropic', ai_access_token: 'sk-ant-' + 'a' * 95)
      organisation.save!(validate: false)
      allow(AiCredential).to receive(:active_for_provider).with('anthropic')
                                                          .and_return(build_stubbed(:ai_credential, provider: 'anthropic', enabled: true, access_token: 'k'))
      expect(described_class.for_chat(organisation)).to be_a(Lalabase::Llm::AnthropicProvider)
    end

    it 'raises on unknown provider name (defense in depth past org validation)' do
      organisation.assign_attributes(ai_provider: 'cohere', ai_access_token: 'k')
      organisation.save!(validate: false)
      expect { described_class.for_chat(organisation) }
        .to raise_error(Lalabase::Llm::Provider::Error, /Unknown LLM provider/)
    end

    it 'includes the offending provider name in the error message (diagnostic)' do
      organisation.assign_attributes(ai_provider: 'gemini', ai_access_token: 'k')
      organisation.save!(validate: false)
      expect { described_class.for_chat(organisation) }
        .to raise_error(/gemini/)
    end
  end

  describe '.for_embeddings' do
    it 'defaults to OpenAiProvider when org has no embedding config' do
      organisation.update!(ai_provider: 'anthropic', ai_access_token: 'sk-ant-' + 'a' * 95)
      allow(AiCredential).to receive(:active_for_provider)
        .with('openai').and_return(build_stubbed(:ai_credential, provider: 'openai', enabled: true, access_token: 'sk-system'))
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    it 'routes embeddings INDEPENDENTLY of chat — never hands the chat token to the embedder' do
      # Critical: an org configured for Anthropic chat must NOT have its anthropic
      # api_key handed to an OpenAI client for embeddings — that would 401 and
      # silently corrupt the index. Embeddings read embedding_* columns, not ai_*.
      organisation.update!(ai_provider: 'anthropic', ai_access_token: 'sk-ant-byok')
      allow(AiCredential).to receive(:active_for_provider)
        .with('openai').and_return(build_stubbed(:ai_credential, provider: 'openai', enabled: true, access_token: 'sk-system-openai'))
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider.api_key).to eq('sk-system-openai')
      expect(provider.api_key).not_to eq('sk-ant-byok')
    end

    it "uses the org's own embedding BYOK token, not its chat ai_access_token" do
      organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-chat',
                           embedding_provider: 'openai', embedding_access_token: 'sk-embed')
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider).to be_a(Lalabase::Llm::OpenAiProvider)
      expect(provider.api_key).to eq('sk-embed')
    end

    it 'returns an OpenAiCompatibleProvider with the org endpoint, model and token' do
      organisation.update!(embedding_provider: 'openai_compatible',
                           embedding_access_token: 'sk-local',
                           embedding_api_base: 'https://llm.internal/v1',
                           embedding_model: 'bge-1536')
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider).to be_a(Lalabase::Llm::OpenAiCompatibleProvider)
      expect(provider.api_key).to eq('sk-local')
      expect(provider.api_base).to eq('https://llm.internal/v1')
      expect(provider.default_embedding_model).to eq('bge-1536')
    end

    it 'falls back to the system openai_compatible credential (uri_base + default_model)' do
      organisation.update!(embedding_provider: 'openai_compatible')
      cred = build_stubbed(:ai_credential, provider: 'openai_compatible', enabled: true,
                                           access_token: 'sk-sys-local', default_model: 'sys-embed-1536',
                                           additional_config: { 'uri_base' => 'https://sys.internal/v1' })
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(cred)
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider).to be_a(Lalabase::Llm::OpenAiCompatibleProvider)
      expect(provider.api_base).to eq('https://sys.internal/v1')
      expect(provider.default_embedding_model).to eq('sys-embed-1536')
    end

    # The twin of the example above, and the half that was missing: since S2 the
    # endpoint lives in the api_base COLUMN, and all three EU presets fill it while
    # setting no legacy uri_base at all. Reading only additional_config['uri_base']
    # therefore handed the provider no endpoint — and it hid the endpoint from the
    # switch guard, whose whole job is telling two deployments apart.
    it 'reads the system endpoint from the api_base COLUMN, not only from legacy uri_base' do
      organisation.update!(embedding_provider: 'openai_compatible')
      cred = build_stubbed(:ai_credential, provider: 'openai_compatible', enabled: true,
                                           access_token: 'sk-sys-column', default_model: 'sys-embed-1536',
                                           api_base: 'https://column.internal/v1', additional_config: nil)
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(cred)

      expect(described_class.for_embeddings(organisation, space: :configured).api_base)
        .to eq('https://column.internal/v1')
    end

    it 'still lets the legacy uri_base serve a credential with no column value' do
      organisation.update!(embedding_provider: 'openai_compatible')
      cred = build_stubbed(:ai_credential, provider: 'openai_compatible', enabled: true,
                                           access_token: 'sk-sys-legacy', default_model: 'sys-embed-1536',
                                           api_base: nil,
                                           additional_config: { 'uri_base' => 'https://legacy.internal/v1' })
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(cred)

      expect(described_class.for_embeddings(organisation, space: :configured).api_base)
        .to eq('https://legacy.internal/v1')
    end

    it 'raises MissingCredentialError when no embedding credential resolves' do
      organisation.update!(embedding_provider: 'openai_compatible')
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(nil)
      expect { described_class.for_embeddings(organisation, space: :configured) }
        .to raise_error(described_class::MissingCredentialError)
    end
  end

  # Embedding dimension precedence (v2 §3.2): org.embedding_dims >
  # credential additional_config['embedding_dims'] > default (nil = unset, the
  # provider then falls back to DEFAULT_EMBEDDING_DIMS in its guard).
  describe '.for_embeddings — embedding dimension resolution (v2 §3.2)' do
    def stub_system_credential(additional_config:)
      cred = build_stubbed(:ai_credential, provider: 'openai', enabled: true,
                                           access_token: 'sk-sys', additional_config: additional_config)
      allow(AiCredential).to receive(:active_for_provider).with('openai').and_return(cred)
    end

    it 'passes nil when neither org nor credential configures a dim (byte-identical to pre-v2)' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_credential(additional_config: nil)
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to be_nil
    end

    it 'reads the dim from the system credential additional_config when the org has none' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_credential(additional_config: { 'embedding_dims' => 1536 })
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to eq(1536)
    end

    # Both values are on the allowlist since PR 5, so the loser really loses on
    # PRECEDENCE here — it is not silently dropped by the clamp.
    it 'lets org.embedding_dims win over the credential additional_config' do
      organisation.update!(embedding_provider: 'openai', embedding_dims: 1536)
      stub_system_credential(additional_config: { 'embedding_dims' => 768 })
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to eq(1536)
    end

    it 'coerces a string additional_config value to an integer' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_credential(additional_config: { 'embedding_dims' => '1536' })
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to eq(1536)
    end

    # The credential additional_config is admin-entered, UNVALIDATED JSON (the
    # admin controller permits `additional_config: {}` wildcard) — the resolver
    # must gate it exactly like the validated org column, or one credential typo
    # re-aims guard_dimensions at a dim no storage lane accepts and breaks
    # embeddings for every org on that credential (review PR #350).
    # 3072 used to be the example here ("no lane until PR 5b"). PR 5b shipped the halfvec
    # lane, so it is on the allowlist now and had to move to the pass-through cases below;
    # 999 keeps the gate under test with a value that is genuinely off-list.
    it 'ignores a credential dim outside SUPPORTED_DIMS' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_credential(additional_config: { 'embedding_dims' => 999 })
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to be_nil
    end

    # Counterpart since PR 5: a dim that IS on the allowlist must pass the clamp —
    # otherwise the gate above could degenerate into "always nil" unnoticed.
    it 'passes a credential dim ON the allowlist through (1024 since PR 5)' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_credential(additional_config: { 'embedding_dims' => 1024 })
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to eq(1024)
    end

    # 3072 gets its own pass-through case rather than riding along with 1024: it is the
    # newest and structurally different lane (halfvec instead of vector, added in PR 5b),
    # so it is the one most likely to be allowlisted in the model but never wired through
    # the resolver — which would look like "3072 is configurable" while every embedding
    # silently fell back to the default.
    it 'passes 3072 through since PR 5b (halfvec lane)' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_credential(additional_config: { 'embedding_dims' => 3072 })
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to eq(3072)
    end

    # Garbage must resolve to unset (→ default), NEVER to 0 (`''.to_i` == 0
    # would send `dimensions: 0` and re-aim the guard at 0) and NEVER raise
    # (false/[]/{} have no #to_i — a plain &.to_i would NoMethodError here).
    ['', '  ', 'abc', '1536x', 0, -1, false, [], {}].each do |garbage|
      it "treats a garbage credential value #{garbage.inspect} as unset (never 0, no raise)" do
        organisation.update!(embedding_provider: 'openai')
        stub_system_credential(additional_config: { 'embedding_dims' => garbage })
        expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to be_nil
      end
    end

    it 'surfaces org.embedding_dims on the BYOK embedding path (extra_config is nil there)' do
      organisation.update!(embedding_provider: 'openai_compatible',
                           embedding_access_token: 'sk-byok',
                           embedding_api_base: 'https://llm.internal/v1',
                           embedding_model: 'bge-1536', embedding_dims: 1536)
      expect(described_class.for_embeddings(organisation, space: :configured).configured_embedding_dims).to eq(1536)
    end
  end

  # Embedding v2 PR 4b: the READ side of the sidecar needs the org's vector-space
  # TRIPLE, resolved through the SAME credential/provider construction as
  # #for_embeddings (so read triple == write stamp by construction) but WITHOUT the
  # ai_enabled/quota gates — a local DB read is neither data egress nor spend, and
  # retrieval must keep serving while a quota is exhausted.
  #
  # This block is also the regression pin for the extraction itself: #for_embeddings
  # must stay gated exactly as before.
  describe '.embedding_space_for' do
    let(:default_triple) do
      { embedding_provider: 'openai', embedding_model: 'text-embedding-3-small', embedding_dims: 1536 }
    end

    def stub_system_openai
      allow(AiCredential).to receive(:active_for_provider)
        .with('openai').and_return(build_stubbed(:ai_credential, provider: 'openai', enabled: true,
                                                                 access_token: 'sk-system'))
    end

    it 'returns exactly EmbeddingColumns.from(for_embeddings(org)) on the SYSTEM path' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_openai
      expected = Lalabase::Indexer::EmbeddingColumns.from(described_class.for_embeddings(organisation, space: :configured))
      expect(described_class.embedding_space_for(organisation, space: :active)).to eq(expected)
      expect(described_class.embedding_space_for(organisation, space: :active)).to eq(default_triple)
    end

    it 'returns exactly EmbeddingColumns.from(for_embeddings(org)) on the BYOK path' do
      organisation.update!(embedding_provider: 'openai_compatible',
                           embedding_access_token: 'sk-byok',
                           embedding_api_base: 'https://llm.internal/v1',
                           embedding_model: 'bge-1536', embedding_dims: 1536)
      expected = Lalabase::Indexer::EmbeddingColumns.from(described_class.for_embeddings(organisation, space: :configured))
      expect(described_class.embedding_space_for(organisation, space: :active)).to eq(expected)
      expect(described_class.embedding_space_for(organisation, space: :active))
        .to eq(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536', embedding_dims: 1536)
    end

    it 'does NOT raise for an org with ai_enabled: false (gate-free by design)' do
      disabled_org = create(:organisation, :ai_disabled, embedding_provider: 'openai')
      stub_system_openai
      expect(described_class.embedding_space_for(disabled_org, space: :active)).to eq(default_triple)
    end

    it 'does NOT consult the quota gate' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_openai
      allow(Lalabase::Llm::Gate).to receive(:ensure_within_quota!)
      described_class.embedding_space_for(organisation, space: :active)
      expect(Lalabase::Llm::Gate).not_to have_received(:ensure_within_quota!)
    end

    it 'still serves the triple when the quota gate WOULD raise' do
      organisation.update!(embedding_provider: 'openai')
      stub_system_openai
      allow(Lalabase::Llm::Gate).to receive(:ensure_within_quota!).and_raise(Lalabase::Llm::QuotaExceededError)
      expect(described_class.embedding_space_for(organisation, space: :active)).to eq(default_triple)
      # ... while the gated write-side entry point keeps failing loudly.
      expect { described_class.for_embeddings(organisation, space: :configured) }.to raise_error(Lalabase::Llm::QuotaExceededError)
    end

    it 'raises MissingCredentialError when nothing resolves (documented, unreachable in real flows)' do
      organisation.update!(embedding_provider: 'openai_compatible')
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(nil)
      expect { described_class.embedding_space_for(organisation, space: :active) }
        .to raise_error(described_class::MissingCredentialError)
    end

    it 'keeps the provider-construction seam private (callers go through the two entries)' do
      expect(described_class).not_to respond_to(:build_embedding_provider)
    end
  end

  # The ACTIVE (serving) leg reads a held embedding_spaces row. Two review
  # findings live here, both invisible from the :configured side.
  describe 'the active leg of a HELD space' do
    # :not_metered rather than :embedding_only, because two examples below flip the
    # purpose to 'chat' and a quota-relevant chat credential must carry prices —
    # an unrelated validation that would otherwise fail the fixture, not the rule.
    let(:held_credential) do
      create(:ai_credential, :openai_compatible, :active, :not_metered,
             purpose: 'embedding', name: 'Mistral held', api_base: 'https://api.mistral.ai/v1',
             default_model: 'mistral-embed', access_token: 'held-token-1234567890')
    end

    def hold_space!(credential)
      space = create(:embedding_space, organisation: organisation, embedding_provider: 'openai_compatible',
                                       embedding_model: 'mistral-embed', embedding_dims: 1024,
                                       ai_credential_id: credential.id)
      organisation.update!(active_embedding_space: space)
      space
    end

    # The curated snapshot records NO endpoint on purpose (it pins the credential
    # id so rotation keeps applying), and the three EU presets fill the api_base
    # COLUMN rather than the legacy additional_config['uri_base']. Reading only
    # the legacy key therefore built an endpoint-less provider on exactly the
    # packages P2 ships: configured writes worked, query embeddings did not.
    it 'resolves the endpoint from the credential COLUMN, not only from legacy uri_base' do
      held_credential.update!(additional_config: {})
      hold_space!(held_credential)

      expect(described_class.for_embeddings(organisation, space: :active).api_base)
        .to eq('https://api.mistral.ai/v1')
    end

    it "still lets the row's own snapshotted endpoint win" do
      hold_space!(held_credential).update!(api_base: 'https://frozen.example/v1')

      expect(described_class.for_embeddings(organisation, space: :active).api_base)
        .to eq('https://frozen.example/v1')
    end

    # One question, one answer: the gate has refused a chat-only credential on this
    # lane since R1 and the :configured leg refuses it since P2 — while this leg
    # kept happily embedding search terms on the very same row.
    it 'refuses a chat-only credential here too, exactly as the configured leg does' do
      held_credential.update!(purpose: 'chat')
      hold_space!(held_credential)

      expect { described_class.for_embeddings(organisation, space: :active) }
        .to raise_error(described_class::MissingCredentialError, /purpose/)
    end

    it 'refuses it on the unpinned active path as well' do
      hold_space!(held_credential).update!(ai_credential_id: nil)
      held_credential.update!(purpose: 'chat')
      Rails.cache.clear

      expect { described_class.for_embeddings(organisation, space: :active) }
        .to raise_error(described_class::MissingCredentialError, /purpose/)
    end
  end

  describe 'credential resolution' do
    it "uses the org's own BYOK token when present" do
      organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-byok')
      provider = described_class.for_chat(organisation)
      expect(provider.api_key).to eq('sk-byok')
    end

    it 'falls back to system AiCredential when org has no BYOK' do
      organisation.update!(ai_provider: 'openai', ai_access_token: nil)
      allow(AiCredential).to receive(:active_for_provider)
        .with('openai').and_return(build_stubbed(:ai_credential, provider: 'openai', enabled: true, access_token: 'sk-system'))
      provider = described_class.for_chat(organisation)
      expect(provider.api_key).to eq('sk-system')
    end

    it 'raises MissingCredentialError when neither BYOK nor system credential exists' do
      organisation.update!(ai_provider: 'openai', ai_access_token: nil)
      allow(AiCredential).to receive(:active_for_provider).with('openai').and_return(nil)
      expect { described_class.for_chat(organisation) }
        .to raise_error(described_class::MissingCredentialError, /No active credential/)
    end

    it 'raises MissingCredentialError when system credential exists but is disabled' do
      organisation.update!(ai_provider: 'openai', ai_access_token: nil)
      disabled = build_stubbed(:ai_credential, provider: 'openai', enabled: false, access_token: 'sk-dead')
      allow(AiCredential).to receive(:active_for_provider).with('openai').and_return(disabled)
      expect { described_class.for_chat(organisation) }
        .to raise_error(described_class::MissingCredentialError)
    end

    it 'MissingCredentialError descends from Provider::Error (caught by a single rescue)' do
      expect(described_class::MissingCredentialError.ancestors).to include(Lalabase::Llm::Provider::Error)
    end

    it 'falls back to system credential when organisation does not respond to has_own_ai_credentials?' do
      bare_org = Object.new
      def bare_org.ai_provider = 'openai'
      # The GDPR opt-in gate runs first and is fail-closed, so even this bare
      # duck-type must answer ai_enabled? affirmatively to get past it.
      def bare_org.ai_enabled? = true
      # included_in_quota: false keeps the S3 quota gate inert here — this test is
      # about credential resolution, not quota, and the bare duck-type has no ai_usages.
      allow(AiCredential).to receive(:active_for_provider)
        .with('openai').and_return(build_stubbed(:ai_credential, provider: 'openai', enabled: true,
                                                                 included_in_quota: false, access_token: 'sk-system'))
      provider = described_class.for_chat(bare_org)
      expect(provider.api_key).to eq('sk-system')
    end

    it 'forwards the OpenAI organization_id header from system credential when set' do
      organisation.update!(ai_provider: 'openai', ai_access_token: nil)
      cred = build_stubbed(:ai_credential, provider: 'openai', enabled: true,
                                           access_token: 'sk-system', organization_id: 'org-abc')
      allow(AiCredential).to receive(:active_for_provider).with('openai').and_return(cred)
      provider = described_class.for_chat(organisation)
      expect(provider.organisation_id_param).to eq('org-abc')
    end
  end

  describe '.for_chat — openai_compatible routing (S2)' do
    it 'builds an OpenAiCompatibleProvider with the credential uri_base, model and effective name' do
      organisation.update!(ai_provider: 'openai_compatible', ai_access_token: nil)
      cred = build_stubbed(:ai_credential, provider: 'openai_compatible', enabled: true,
                                           access_token: 'sk-mistral', default_model: 'mistral-small',
                                           api_base: 'https://mistral.eu/v1', display_name: 'Mistral EU')
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(cred)

      provider = described_class.for_chat(organisation)
      expect(provider).to be_a(Lalabase::Llm::OpenAiCompatibleProvider)
      expect(provider.api_base).to eq('https://mistral.eu/v1')
      expect(provider.default_chat_model).to eq('mistral-small')
      # Attribution/provenance carry the EFFECTIVE name; the routing key stays generic.
      expect(provider.effective_provider_name).to eq('Mistral EU')
      expect(provider.provider_name).to eq('openai_compatible')
    end

    it 'falls back to the legacy additional_config uri_base when api_base is blank' do
      organisation.update!(ai_provider: 'openai_compatible', ai_access_token: nil)
      cred = build_stubbed(:ai_credential, provider: 'openai_compatible', enabled: true,
                                           access_token: 'sk-x', default_model: 'm', api_base: nil,
                                           additional_config: { 'uri_base' => 'https://legacy.internal/v1' })
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(cred)
      expect(described_class.for_chat(organisation).api_base).to eq('https://legacy.internal/v1')
    end

    it 'prefers the api_base column over the legacy uri_base when BOTH are set (precedence, not either/or)' do
      organisation.update!(ai_provider: 'openai_compatible', ai_access_token: nil)
      cred = build_stubbed(:ai_credential, provider: 'openai_compatible', enabled: true,
                                           access_token: 'sk-x', default_model: 'm', api_base: 'https://new.eu/v1',
                                           additional_config: { 'uri_base' => 'https://legacy.eu/v1' })
      allow(AiCredential).to receive(:active_for_provider).with('openai_compatible').and_return(cred)
      expect(described_class.for_chat(organisation).api_base).to eq('https://new.eu/v1')
    end
  end

  # ⚠️ REWRITTEN in the review of S7, and the old title was the defect: there was no
  # single "precedence", there were two branches, and the org column had a meaning in
  # exactly one of them. The examples below used to PIN the wrong behaviour — three of
  # them set `ai_access_token: nil` (i.e. the SYSTEM branch) and then asserted that the
  # org's column won there.
  #
  # The rule now: whoever owns the key names the model.
  #   BYOK      → organisation.preferred_chat_model, else the provider constant
  #   system    → credential.default_model, else the provider constant
  #   package   → the rung (AiPackageTier#effective_chat_model) — see 'curated package
  #               routing (P2)', which always said so
  describe 'which model runs on which key' do
    let(:system_credential) do
      build_stubbed(:ai_credential, provider: 'openai', enabled: true,
                                    access_token: 'sk-operator-system-key', default_model: 'gpt-4o')
    end

    context 'on the organisation\'s OWN key (BYOK)' do
      it 'uses organisation.preferred_chat_model — the column belongs to this branch' do
        organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-byok', preferred_chat_model: 'gpt-4-turbo')
        expect(described_class.for_chat(organisation).default_chat_model).to eq('gpt-4-turbo')
      end

      it 'falls back to the provider constant without a preference' do
        organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-byok', preferred_chat_model: nil)
        expect(described_class.for_chat(organisation).default_chat_model)
          .to eq(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL)
      end

      # Kills a mutation dropping `.presence`: a bare `preferred_chat_model` would pass ""
      # through (truthy in Ruby) and the provider would receive an empty model name.
      it 'treats a BLANK preference as no preference (empty string is truthy in Ruby)' do
        organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-byok', preferred_chat_model: '')
        expect(described_class.for_chat(organisation).default_chat_model)
          .to eq(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL)
      end
    end

    context 'on the OPERATOR\'s key (system credential)' do
      before { allow(AiCredential).to receive(:active_for_provider).with('openai').and_return(system_credential) }

      it 'uses credential.default_model' do
        organisation.update!(ai_provider: 'openai', ai_access_token: nil, preferred_chat_model: nil)
        expect(described_class.for_chat(organisation).default_chat_model).to eq('gpt-4o')
      end

      # ── THE regression. Nobody finds this one by reading: the two attributes it
      # asserts come from the SAME branch, and only together do they say what was
      # wrong. Measured before the fix — api_key was the operator's system key while
      # chat_model was the customer's free text, i.e. the customer chose which model
      # runs on our invoice.
      #
      # The route is not hypothetical and not "BYOK orgs are excluded": this org HAS
      # its own access, for openai_compatible. Every seam pinned to `openai`
      # (:customer_description is one) therefore lands on the system branch for it,
      # because has_own_ai_credentials?('openai') is false. The pin is the second
      # casualty — it names a model because REASONING_MODEL_PATTERN switches the
      # request dialect, so an override is a broken request, not a preference.
      it 'ignores organisation.preferred_chat_model — the customer does not pick the model on our key' do
        organisation.update!(ai_provider: 'openai_compatible', ai_access_token: 'byok-token',
                             ai_api_base: 'https://api.mistral.ai/v1',
                             preferred_chat_model: 'o3-pro-expensive')

        creds = described_class.resolve_credentials('openai', organisation)

        expect(creds[:api_key]).to eq('sk-operator-system-key')
        expect(creds[:chat_model]).to eq('gpt-4o')
      end
    end
  end

  describe 'PROVIDER_CLASSES mapping (whitelist)' do
    described_class::PROVIDER_CLASSES.each_pair do |key, klass|
      it "maps #{key.inspect} to #{klass.name}" do
        expect(klass.ancestors).to include(Lalabase::Llm::Provider)
      end
    end

    it 'allows openai, anthropic, openai_compatible and google' do
      expect(described_class::PROVIDER_CLASSES.keys)
        .to contain_exactly('openai', 'anthropic', 'openai_compatible', 'google')
    end
  end

  # GoogleVertexProvider routing (Slice 3): 'google' resolves through the SAME
  # gated seam as every other provider — registering the class in
  # PROVIDER_CLASSES is what dropped the S1 facade, and the credential's
  # additional_config (project_id/location) must reach the provider or its
  # fail-fast config check fires on the first call.
  describe '.for_chat — google routing (Slice 3)' do
    let(:google_credential) do
      build_stubbed(:ai_credential, :google, enabled: true, display_name: 'Google Vertex AI (EU)')
    end

    before do
      organisation.update!(ai_provider: 'google', ai_access_token: nil)
      allow(AiCredential).to receive(:active_for_provider).with('google').and_return(google_credential)
    end

    it 'builds a GoogleVertexProvider with the SA JSON and threads additional_config through' do
      provider = described_class.for_chat(organisation)
      expect(provider).to be_a(Lalabase::Llm::GoogleVertexProvider)
      expect(provider.api_key).to eq(google_credential.access_token)
      expect(provider.additional_config).to eq('project_id' => 'lala-eu', 'location' => 'europe-west3')
      expect(provider.default_chat_model).to eq('gemini-2.0-flash')
      expect(provider.effective_provider_name).to eq('Google Vertex AI (EU)')
      expect(provider.provider_name).to eq('google')
    end

    it 'passes google through the quota gate like every chat provider' do
      allow(Lalabase::Llm::Gate).to receive(:ensure_within_quota!)
      described_class.for_chat(organisation)
      # P0: the gate receives the resolved credential (the one the call bills).
      expect(Lalabase::Llm::Gate)
        .to have_received(:ensure_within_quota!).with(organisation, credential: google_credential)
    end

    it 'raises AiDisabledError for a non-opted-in org (the GDPR gate covers google automatically)' do
      disabled_org = create(:organisation, :ai_disabled, ai_provider: 'google')
      expect { described_class.for_chat(disabled_org) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end
  end

  describe '.for_embeddings — google routing (Slice 3)' do
    it 'builds a GoogleVertexProvider with additional_config from the system credential' do
      organisation.update!(embedding_provider: 'google')
      cred = build_stubbed(:ai_credential, :google, enabled: true)
      allow(AiCredential).to receive(:active_for_provider).with('google').and_return(cred)

      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider).to be_a(Lalabase::Llm::GoogleVertexProvider)
      expect(provider.additional_config).to eq('project_id' => 'lala-eu', 'location' => 'europe-west3')
      expect(provider.default_embedding_model).to eq('gemini-embedding-001')
    end
  end

  # GDPR org-level AI opt-in (audit 2026-07-03, item 1.2): the factory is THE
  # seam every external LLM/embedding call resolves through, so the gate here
  # guarantees no tenant content leaves for a provider without activation.
  # Intent: raise a dedicated domain error for a non-opted-in org on EVERY
  # factory entry point — regardless of which credentials would be available.
  describe 'GDPR AI opt-in gate' do
    let(:disabled_org) do
      create(:organisation, :ai_disabled, ai_provider: 'openai', ai_access_token: 'sk-test')
    end

    it 'raises AiDisabledError from .for_chat when the org has not opted in' do
      expect { described_class.for_chat(disabled_org) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'never touches credential resolution for a disabled org (gate fires first)' do
      # The DSGVO promise is "no call path even starts": a mutation that moves
      # ensure_ai_enabled! behind resolve_credentials would still raise, but
      # would have read credential state — pin the gate to the front.
      # DELIBERATELY an org WITHOUT its own token: with a BYOK token the
      # own-credentials branch never consults AiCredential anyway, and this
      # spy could not distinguish gate-first from gate-last (red-team finding).
      bare_disabled_org = create(:organisation, :ai_disabled, ai_provider: 'openai', ai_access_token: nil)

      expect(AiCredential).not_to receive(:active_for_provider)
      expect { described_class.for_chat(bare_disabled_org) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
      expect { described_class.for_embeddings(bare_disabled_org, space: :configured) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'raises AiDisabledError from .for_embeddings when the org has not opted in' do
      expect { described_class.for_embeddings(disabled_org, space: :configured) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'raises AiDisabledError from .build (direct entry) when the org has not opted in' do
      expect { described_class.build(provider_name: 'openai', organisation: disabled_org) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'raises AiDisabledError for a nil organisation (defensive default, BOTH entries)' do
      # for_chat must not read ai_provider before the gate — a nil org would
      # then surface as NoMethodError instead of the fail-closed domain error.
      expect { described_class.for_chat(nil) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
      expect { described_class.for_embeddings(nil, space: :configured) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'still resolves a provider for an opted-in org (regression guard)' do
      organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-test')
      expect(described_class.for_chat(organisation)).to be_a(Lalabase::Llm::OpenAiProvider)
    end

    it 'inherits from Provider::Error so broad provider rescues degrade gracefully' do
      expect(Lalabase::Llm::AiDisabledError.ancestors).to include(Lalabase::Llm::Provider::Error)
    end

    # THE one documented exception, and it belongs next to the rule rather than in the
    # spec of its caller (doc/ki_bereich_navigation_plan.md S7, gap L6). Every example
    # above pins that a build path is gated; .chat_probe is the diagnostic that must not
    # be, because connectivity_check lists models — it sends no tenant content and spends
    # no tokens. Gated, it refused the organisation that was configuring itself, which is
    # the normal state while setting up.
    #
    # Asserted on the REAL seam. Its caller's spec stubs .chat_probe to classify outcomes,
    # so a gate re-added here would be invisible over there — measured: with
    # ensure_ai_enabled! put back into .chat_probe, all thirteen examples of
    # connection_check_spec stayed green.
    describe '.chat_probe (the diagnostic exception)' do
      it 'builds a provider for an org that has NOT opted in' do
        expect(described_class.chat_probe(disabled_org)).to be_a(Lalabase::Llm::OpenAiProvider)
      end

      # Same routing as the real call, not a second resolution: a probe free to resolve
      # its own credentials could report green for a credential no request ever uses.
      it 'resolves the same provider the real chat call would' do
        disabled_org.update!(ai_provider: 'anthropic', ai_access_token: "sk-ant-#{'a' * 95}")

        expect(described_class.chat_probe(disabled_org)).to be_a(Lalabase::Llm::AnthropicProvider)
      end

      # The quota gate is the second one it skips: an exhausted budget is a statement
      # about credits, not about whether the access answers.
      it 'does not consult the quota gate' do
        expect(Lalabase::Llm::Gate).not_to receive(:ensure_within_quota!)

        described_class.chat_probe(disabled_org)
      end

      # It is a DIAGNOSTIC exemption, not a hole: a probe still cannot invent an access.
      it 'still refuses when no access resolves at all' do
        bare = create(:organisation, :ai_disabled, ai_provider: 'openai', ai_access_token: nil)

        expect { described_class.chat_probe(bare) }
          .to raise_error(Lalabase::Llm::Factory::MissingCredentialError)
      end
    end
  end

  # P0 (doc/ki_pakete_plan.md §4.1): the Factory resolves the system credential
  # ONCE and carries it on the provider. Gate + UsageTracking judge THIS object —
  # with several credentials of the same provider in service (packages), a second
  # name-based resolution would gate/bill a different credential than the one
  # that served the call.
  describe 'billing credential carried on the provider (P0)' do
    it '.build carries the resolved system credential' do
      credential = create(:ai_credential, :active, provider: 'openai')
      provider = described_class.build(provider_name: 'openai', organisation: organisation)
      expect(provider.billing_credential).to eq(credential)
    end

    it '.build carries nil for a BYOK org (we do not bill that call)' do
      create(:ai_credential, :active, provider: 'openai')
      organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-org-own-key-123456789')
      provider = described_class.for_chat(organisation)
      expect(provider.billing_credential).to be_nil
    end

    it '.for_embeddings carries the resolved system credential' do
      credential = create(:ai_credential, :active, provider: 'openai')
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider.billing_credential).to eq(credential)
    end

    it '.for_embeddings carries nil on the embedding-BYOK path' do
      create(:ai_credential, :active, provider: 'openai')
      organisation.update!(embedding_provider: 'openai', embedding_access_token: 'sk-own-emb-key-123456')
      provider = described_class.for_embeddings(organisation, space: :configured)
      expect(provider.billing_credential).to be_nil
    end
  end

  # KI-Pakete P2 (doc/ki_pakete_plan.md §6.1, E1-C/E11): the org's PACKAGE
  # decides, and it decides by naming a credential ROW — not a provider.
  #
  # The whole block is built on the case that makes that distinction visible:
  # TWO openai_compatible credentials side by side (Mistral FR and IONOS DE, the
  # normal shape of the EU packages, §4.1). Under name resolution the package
  # would silently receive the other provider's token; every "by id" claim below
  # is measured against that.
  describe 'curated package routing (P2)' do
    # The standard credential of the provider — deliberately NOT the one the
    # package points at, so any fallback to active_for_provider shows up as the
    # wrong token rather than as an error.
    let!(:ionos_standard) do
      create(:ai_credential, :openai_compatible, :active, :eu_company,
             name: 'IONOS DE', display_name: 'IONOS AI Model Hub (DE)',
             api_base: 'https://ionos.example/v1', default_model: 'llama-3.3-70b',
             access_token: 'ionos-token-0987654321')
    end

    let!(:mistral_chat) do
      create(:ai_credential, :openai_compatible, :eu_company,
             name: 'Mistral FR chat', display_name: 'Mistral (EU)',
             default_model: 'mistral-small-latest', access_token: 'mistral-chat-token-123456')
    end

    let!(:mistral_embed) do
      create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
             name: 'Mistral FR embed', default_model: 'mistral-embed-legacy',
             access_token: 'mistral-embed-token-123')
    end

    let(:package) do
      package = create(:ai_package, name: 'Europäisch (Mistral)', embedding_credential: mistral_embed,
                                    embedding_model: 'mistral-embed', embedding_dims: 1024)
      package.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0,
                            chat_credential: mistral_chat)
      package.tiers.create!(key: 'thorough', label: 'Gründlich', position: 1,
                            chat_credential: mistral_chat, chat_model: 'mistral-large-latest')
      package
    end

    # ai_provider stays 'openai' on purpose: a package that only worked for orgs
    # whose columns already agreed with it would prove nothing.
    def put_on_package(tier_key: nil)
      organisation.update!(ai_package: package, ai_package_tier_key: tier_key,
                           ai_provider: 'openai', embedding_provider: 'openai')
      organisation
    end

    # Whose access does the chat run on? The caller that has to NAME the owner of a
    # failed request (ChatResponseJob#refused_copy) asks this instead of deriving it,
    # so it has to answer for the same branch #resolve_credentials takes.
    describe '.own_chat_access?' do
      it 'is false on a curated package even when the org still holds its own token' do
        put_on_package
        organisation.update!(ai_access_token: 'sk-left-over-from-before-the-package')
        expect(described_class.own_chat_access?(organisation)).to be(false)
      end

      it 'is true when the org routes on its own token' do
        organisation.update!(ai_provider: 'anthropic', ai_access_token: 'sk-ant-' + ('a' * 95))
        expect(described_class.own_chat_access?(organisation)).to be(true)
      end

      it 'is false when the request would fall through to the system credential' do
        organisation.update!(ai_provider: 'openai', ai_access_token: nil)
        expect(described_class.own_chat_access?(organisation)).to be(false)
      end
    end

    describe 'chat lane' do
      it 'names the package provider, not the org column (Art. 13 notice)' do
        expect(described_class.chat_provider_name(put_on_package)).to eq('openai_compatible')
      end

      it 'resolves the TIER credential by id, never the provider standard' do
        provider = described_class.for_chat(put_on_package)

        expect(provider.api_key).to eq('mistral-chat-token-123456')
        expect(provider.api_key).not_to eq(ionos_standard.access_token)
        expect(provider.api_base).to eq('https://api.mistral.ai/v1')
      end

      it 'bills the tier credential (P0 attribution)' do
        expect(described_class.for_chat(put_on_package).billing_credential).to eq(mistral_chat)
      end

      # §6.1 Detailkonflikt 1: a leftover value in the org column must not
      # override the rung the customer picked — the column is not even shown on
      # the package screen.
      it 'ignores a leftover preferred_chat_model' do
        put_on_package.update!(preferred_chat_model: 'gpt-4-turbo')

        expect(described_class.for_chat(organisation).default_chat_model).to eq('mistral-small-latest')
      end

      it 'lets tier.chat_model win over credential.default_model' do
        expect(described_class.for_chat(put_on_package(tier_key: 'thorough')).default_chat_model)
          .to eq('mistral-large-latest')
      end

      it 'falls back to the fast rung for a blank tier_key (P3 ships the switch)' do
        expect(described_class.for_chat(put_on_package).default_chat_model).to eq('mistral-small-latest')
      end

      # Data drift, not user input: the actor validates the key on write. Falling
      # back is a COST decision and cannot break a jurisdiction promise, so it
      # may degrade quietly where the credential resolution may not.
      it 'falls back to the fast rung for a key the package does not offer' do
        organisation.update!(ai_package: package)
        organisation.update_columns(ai_package_tier_key: 'legacy_premium')

        expect(described_class.for_chat(organisation.reload).default_chat_model).to eq('mistral-small-latest')
      end

      # The refusal now covers three conditions (enabled, purpose, endpoint — the
      # embedding twin has asked all three for longer), so the message names which
      # one failed rather than saying "disabled". Still asserted on the REASON, not
      # just the class: a message that stopped naming the cause would turn every
      # curated chat fault into the same undiagnosable raise.
      it 'refuses a disabled tier credential instead of falling back to the standard one' do
        put_on_package
        mistral_chat.update_columns(enabled: false)

        expect { described_class.for_chat(organisation) }
          .to raise_error(described_class::MissingCredentialError, /cannot serve chat.*enabled: false/)
      end

      # A pin bypasses the org's choice by DESIGN (registry :customer_description).
      # Handing that build the package credential would send a Mistral token to
      # OpenAiProvider — the silent wrong-token swap, arriving from the other side.
      it 'does not hand the package credential to a pinned build of another provider' do
        openai_standard = create(:ai_credential, :active, provider: 'openai', access_token: 'sk-system-openai-123')
        put_on_package

        provider = described_class.for_feature(:customer_description, organisation)

        expect(provider).to be_a(Lalabase::Llm::OpenAiProvider)
        expect(provider.billing_credential).to eq(openai_standard)
      end
    end

    describe 'embedding lane' do
      it 'names the package embedding provider' do
        expect(described_class.embedding_provider_name(put_on_package)).to eq('openai_compatible')
      end

      # E11: the package owns the whole triple. credential.default_model is the
      # value it must NOT inherit — it says something else here for that reason.
      it 'uses the package model verbatim and the package dimension' do
        provider = described_class.for_embeddings(put_on_package, space: :configured)

        expect(provider.default_embedding_model).to eq('mistral-embed')
        expect(provider.default_embedding_model).not_to eq(mistral_embed.default_model)
        expect(provider.expected_embedding_dims).to eq(1024)
      end

      it 'ignores a leftover org embedding_dims' do
        put_on_package.update!(embedding_dims: 1536)

        expect(described_class.for_embeddings(organisation, space: :configured).expected_embedding_dims).to eq(1024)
      end

      it 'resolves the package credential by id, not the provider standard' do
        provider = described_class.for_embeddings(put_on_package, space: :configured)

        expect(provider.api_key).to eq('mistral-embed-token-123')
        expect(provider.billing_credential).to eq(mistral_embed)
      end

      # The package governs this lane, so there is no own-secret case left —
      # BYOK columns from the org's pre-package days must not resurface.
      it 'overrides org BYOK embedding columns' do
        put_on_package.update!(embedding_provider: 'openai', embedding_access_token: 'sk-own-emb-key-123456')

        expect(described_class.for_embeddings(organisation, space: :configured).api_key)
          .to eq('mistral-embed-token-123')
      end

      # The pin freezes the ASSIGNMENT space→credential (§7b.2). For a curated
      # org that assignment is the package's, and with two openai_compatible rows
      # the provider standard is a DIFFERENT row, not a stale one.
      it 'snapshots the package credential as the space pin' do
        expect(described_class.embedding_credentials_for(put_on_package))
          .to eq(api_base: nil, access_token: nil, organization_id: nil, ai_credential_id: mistral_embed.id)
      end
    end

    describe '.embedding_triple_for' do
      it 'answers for a HYPOTHETICAL package without touching the org' do
        triple = described_class.embedding_triple_for(organisation, package: package)

        expect(triple).to eq(embedding_provider: 'openai_compatible', embedding_model: 'mistral-embed',
                             embedding_dims: 1024)
        expect(organisation.reload.ai_package_id).to be_nil
      end

      # Both sides of the switch comparison must come from ONE derivation. Passing
      # nil reproduces the custom reading, which is what a deselection resolves to.
      it 'reproduces the configured space of the org it is asked about' do
        create(:ai_credential, :active, provider: 'openai')
        put_on_package

        expect(described_class.embedding_triple_for(organisation, package: package))
          .to eq(described_class.embedding_space_for(organisation, space: :configured))
        expect(described_class.embedding_triple_for(organisation, package: nil))
          .not_to eq(described_class.embedding_space_for(organisation, space: :configured))
      end
    end

    # WHICH credential an embedding run bills — the seam the P4b dialog and
    # Embeddings::SwitchProgress both ask, so a price quoted before a switch and a
    # "pausiert" reported during it cannot come from two derivations (KI-Pakete P4c).
    #
    # The asymmetry these examples exist for: OMITTING `package:` asks "the lane this
    # org is on now", while passing an explicit nil asks the CUSTOM reading of E1-C —
    # the lane it would be on with no package at all. Both callers are correct today
    # and nothing held them there (P4c review, M3); a reader taking the two for the
    # same question would silently move a quota check onto the wrong lane.
    describe '.embedding_billing_credential' do
      it 'answers with the package credential when `package:` is omitted' do
        put_on_package

        expect(described_class.embedding_billing_credential(organisation)).to eq(mistral_embed)
      end

      it 'answers with the org own lane when `package: nil` is passed explicitly' do
        system_openai = create(:ai_credential, :active, provider: 'openai')
        put_on_package

        expect(described_class.embedding_billing_credential(organisation, package: nil))
          .to eq(system_openai)
      end

      # nil is the "not metered" answer the quota checks hang on: with the org's own
      # key nothing bills our system credential, so no gate stops the run and no page
      # may claim it is paused.
      it 'answers nil for a BYOK embedding lane' do
        create(:ai_credential, :active, provider: 'openai')
        organisation.update!(embedding_provider: 'openai',
                             embedding_access_token: 'sk-own-emb-key-123456')

        expect(described_class.embedding_billing_credential(organisation, package: nil)).to be_nil
      end
    end

    # Review finding: the triple does NOT identify the credential, and P2 is what
    # first put a customer control on this. Two openai_compatible credentials
    # (Mistral FR next to IONOS DE — the normal case for the EU packages, §4.1)
    # serving the same model at the same dimension produce an IDENTICAL triple, so
    # a triple-only guard waved the switch through as a no-op: every following
    # vector then came from a different deployment, mixed into the same space,
    # while the jurisdiction badge kept naming the package the customer picked.
    describe '.embedding_switch? — the lane identity, not just the triple' do
      # Same provider, same model, same dimension — different COMPANY.
      let!(:ionos_embed) do
        create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
               name: 'IONOS DE embed', api_base: 'https://ionos.example/v1',
               default_model: 'shared-embed', access_token: 'ionos-embed-token-123')
      end

      let(:twin_package) do
        twin = create(:ai_package, name: 'Europäisch (IONOS)', embedding_credential: ionos_embed,
                                   embedding_model: 'shared-embed', embedding_dims: 1024)
        twin.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0, chat_credential: ionos_standard)
        twin.tiers.create!(key: 'thorough', label: 'Gründlich', position: 1, chat_credential: ionos_standard)
        twin
      end

      before { package.update!(embedding_model: 'shared-embed') }

      it 'reports the same triple for both packages — which is exactly the trap' do
        expect(described_class.embedding_triple_for(organisation, package: package))
          .to eq(described_class.embedding_triple_for(organisation, package: twin_package))
      end

      it 'still calls a Mistral→IONOS move a switch, because the endpoint changes' do
        put_on_package

        expect(described_class.embedding_switch?(organisation, package: twin_package)).to be(true)
      end

      it 'names the endpoint alongside the triple in the identity' do
        put_on_package

        expect(described_class.embedding_identity_for(organisation, package: package))
          .to eq(triple: { embedding_provider: 'openai_compatible', embedding_model: 'shared-embed',
                           embedding_dims: 1024 },
                 api_base: 'https://api.mistral.ai/v1')
      end

      it 'still calls the org’s own package a no-op' do
        put_on_package

        expect(described_class.embedding_switch?(organisation, package: package)).to be(false)
      end

      # The counterweight to the example above, and the reason the identity keys on
      # the ENDPOINT rather than on the credential row: a curated package almost
      # always brings its own row, so keying on the id would call every first
      # selection a switch and freeze P2 whole instead of guarding it.
      it 'does not call a different credential ROW at the same endpoint a switch' do
        put_on_package
        same_endpoint = create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
                               name: 'Mistral FR embed (rotiert)',
                               api_base: mistral_embed.api_base,
                               access_token: 'mistral-embed-token-rotated')
        rotated = create(:ai_package, name: 'Europäisch (Mistral, rotiert)',
                                      embedding_credential: same_endpoint,
                                      embedding_model: 'shared-embed', embedding_dims: 1024)
        rotated.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0, chat_credential: mistral_chat)
        rotated.tiers.create!(key: 'thorough', label: 'Gründlich', position: 1, chat_credential: mistral_chat)

        expect(same_endpoint.id).not_to eq(mistral_embed.id)
        expect(described_class.embedding_switch?(organisation, package: rotated)).to be(false)
      end

      it 'is nil-safe and fails closed when nothing resolves' do
        put_on_package
        mistral_embed.update_columns(enabled: false)
        Rails.cache.clear
        # Reloaded on purpose: update_columns bypasses the in-memory records, and a
        # stale association would let this example pass while proving nothing.
        fresh = AiPackage.find(package.id)

        expect(described_class.embedding_switch?(nil, package: fresh)).to be(false)
        expect(described_class.embedding_switch?(organisation.reload, package: fresh)).to be(true)
      end
    end

    # Gate and routing must judge the same call the same way. The gate has asked
    # for an embedding purpose since R1; this resolution asked only for `enabled`,
    # so a chat-only credential made the gate say no while the factory happily
    # built an embedder on it.
    describe 'purpose asymmetry (review finding)' do
      # update_columns AFTER the package exists: the package's own validation
      # rejects a chat-only embedding credential, so this state only arises the
      # way it would in production — the purpose changed under a live package.
      it 'refuses a chat-only PACKAGE credential' do
        put_on_package
        mistral_embed.update_columns(purpose: 'chat', embedding_cost_per_1m_cents: nil)

        expect { described_class.for_embeddings(organisation, space: :configured) }
          .to raise_error(described_class::MissingCredentialError, /purpose/)
      end

      # Behaviour change on the CUSTOM path, deliberately: a chat-only system
      # credential used to carry embeddings.
      it 'refuses a chat-only SYSTEM credential (custom path)' do
        create(:ai_credential, :active, :chat_only, provider: 'openai')

        expect { described_class.for_embeddings(organisation, space: :configured) }
          .to raise_error(described_class::MissingCredentialError, /purpose/)
      end

      it 'and the gate says the same thing about that org' do
        create(:ai_credential, :active, :chat_only, provider: 'openai')

        expect(organisation.has_valid_embedding_configuration?('openai')).to be(false)
      end
    end

    # E1-C: a `custom` row is the placeholder for "the org's own settings", so it
    # must resolve exactly like ai_package_id NULL — otherwise the seeds row P2
    # may add would become a third code path.
    it 'treats a custom package like no package at all' do
      create(:ai_credential, :active, provider: 'openai')
      custom = AiPackage.create!(kind: 'custom', name: 'Eigene Konfiguration')
      organisation.update!(ai_package: custom, ai_provider: 'anthropic')

      expect(described_class.chat_provider_name(organisation)).to eq('anthropic')
      expect(described_class.embedding_provider_name(organisation)).to eq('openai')
    end

    # What the Art. 13 notice reads (P5): one resolution, one answer object.
    describe '.routing_disclosure' do
      it 'hands the notice the package and the package-resolved provider names' do
        disclosure = described_class.routing_disclosure(put_on_package)

        # Both org columns say 'openai' (put_on_package sets them on purpose) —
        # a disclosure answering off the columns fails BOTH name expectations.
        expect(disclosure.package).to eq(package)
        expect(disclosure.chat_provider_name).to eq('openai_compatible')
        expect(disclosure.embedding_provider_name).to eq('openai_compatible')
        # No held space row: the configured lane serves, which IS the package
        # lane — the jurisdiction line may stand.
        expect(disclosure.search_on_package_lane).to be(true)
      end

      # §3.4: on a package the provider NAME is 'openai_compatible' for every EU
      # preset — the credential's display_label is what tells a Mistral customer
      # they talk to Mistral, and it is the same string the package card shows.
      # The embedding row carries no display_name, so its label falls back to
      # `name` — display_label's own chain, shared with the card's tier list.
      it 'labels the recipients off the resolved credentials, not the provider name' do
        disclosure = described_class.routing_disclosure(put_on_package)

        expect(disclosure.chat_provider_label).to eq('Mistral (EU)')
        expect(disclosure.embedding_provider_label).to eq('Mistral FR embed')
      end

      # A `kind: custom` row must not surface as a curated jurisdiction claim:
      # the routing runs off the org columns, so a notice presenting the row's
      # (blank) jurisdiction would describe a package no request ever reaches.
      it 'hands the notice NO package under custom semantics' do
        create(:ai_credential, :active, provider: 'openai')
        custom = AiPackage.create!(kind: 'custom', name: 'Eigene Konfiguration')
        organisation.update!(ai_package: custom, ai_provider: 'anthropic')

        disclosure = described_class.routing_disclosure(organisation)

        expect(disclosure.package).to be_nil
        expect(disclosure.chat_provider_name).to eq('anthropic')
        expect(disclosure.embedding_provider_name).to eq('openai')
        # No credential resolution off a package — the labels are the generic
        # provider display names, i.e. the notice's prior behaviour.
        expect(disclosure.chat_provider_label).to eq('Anthropic (Claude)')
        expect(disclosure.embedding_provider_label).to eq('OpenAI (GPT)')
        # Not applicable without a package — nil, not false.
        expect(disclosure.search_on_package_lane).to be_nil
      end

      it 'answers for an org without any package row' do
        disclosure = described_class.routing_disclosure(organisation)

        expect(disclosure.package).to be_nil
        expect(disclosure.chat_provider_name).to eq(described_class.chat_provider_name(organisation))
      end

      # MAJOR 1 of the P5 review: search reads the ACTIVE space, not the
      # configured lane. During a staged switch (package selected, old space
      # still serving until P4d's watcher flips) the notice must name the
      # recipient that actually receives every query input — a disclosure
      # answering off embedding_provider_name names the NEW provider while the
      # OLD one still serves.
      it 'names the ACTIVE space recipient during a staged switch, not the configured lane' do
        old_system = create(:ai_credential, :active, provider: 'openai', display_name: 'OpenAI (System)')
        space = create(:embedding_space, organisation: organisation, ai_credential_id: old_system.id)
        put_on_package.update!(active_embedding_space_id: space.id)

        disclosure = described_class.routing_disclosure(organisation.reload)

        aggregate_failures do
          # The configured lane says Mistral — the SERVED space says openai.
          expect(described_class.embedding_provider_name(organisation)).to eq('openai_compatible')
          expect(disclosure.embedding_provider_name).to eq('openai')
          # The label follows the space row's own pinned credential.
          expect(disclosure.embedding_provider_label).to eq('OpenAI (System)')
          # The chat side is untouched by the switch window.
          expect(disclosure.chat_provider_label).to eq('Mistral (EU)')
          # The serving space is NOT the package lane — the notice must drop
          # the jurisdiction line (pre-landing review, KRITISCH 1).
          expect(disclosure.search_on_package_lane).to be(false)
        end
      end

      # The flip restores the claim: once the active row pins the PACKAGE's
      # own embedding credential (which is what ensure_space/flip stamp), the
      # search runs in the package's legal space again. Pin identity, not the
      # triple — two EU presets can produce an identical triple on different
      # endpoints (embedding_identity_of), the pin is the endpoint-and-company
      # fact the jurisdiction claim rests on.
      it 'reports the package lane as serving again after the flip' do
        put_on_package
        space = create(:embedding_space, organisation: organisation,
                                         embedding_provider: 'openai_compatible',
                                         embedding_model: 'mistral-embed', embedding_dims: 1024,
                                         ai_credential_id: mistral_embed.id)
        organisation.update!(active_embedding_space_id: space.id)

        disclosure = described_class.routing_disclosure(organisation.reload)

        expect(disclosure.search_on_package_lane).to be(true)
        expect(disclosure.embedding_provider_label).to eq('Mistral FR embed')
      end

      # Pre-landing review, point 2: ONE row lookup per disclosure — the
      # first cut resolved the active row twice (once directly, once inside
      # embedding_descriptor), doubling queries and dangling-pointer warnings
      # on every chat page render.
      it 'resolves the active space row exactly once' do
        space = create(:embedding_space, organisation: organisation)
        put_on_package.update!(active_embedding_space_id: space.id)
        organisation.reload

        expect(EmbeddingSpace).to receive(:find_by).once.and_call_original

        described_class.routing_disclosure(organisation)
      end

      # The degrade path: a held space whose pinned credential cannot be
      # resolved must not raise out of the notice — chat still works when
      # search does not. The provider is still named, the label falls back,
      # and an unproven lane identity fails closed on the jurisdiction line.
      it 'degrades to the space provider name when the space credential cannot resolve' do
        space = create(:embedding_space, organisation: organisation, embedding_provider: 'anthropic')
        put_on_package.update!(active_embedding_space_id: space.id)

        disclosure = described_class.routing_disclosure(organisation.reload)

        expect(disclosure.embedding_provider_name).to eq('anthropic')
        expect(disclosure.embedding_provider_label).to eq('Anthropic (Claude)')
        expect(disclosure.search_on_package_lane).to be(false)
      end
    end

    # THE compliance claim of P2, as one uninterrupted chain on ONE organisation.
    # The examples above each pin a single link, which is what makes them readable
    # — but a chain is only as strong as the fact that all its links hold for the
    # SAME org at the SAME time. A refactor that moved one seam back onto
    # `active_for_provider` could leave every single-link example green while the
    # legal notice, the routing and the billing record start naming three
    # different credentials.
    #
    # Read as a sentence: what we TELL the customer (Art. 13), where the request
    # actually GOES, who gets BILLED for it, which vector space it writes, what
    # the UI is allowed to OFFER, and what a new embedding space would be pinned
    # to — all six answers have to be the package's, not the org column's and not
    # the provider's standard row.
    it 'answers Art. 13, routing, billing, vector space, gate and pin with the SAME package credential' do
      put_on_package

      chat = described_class.for_chat(organisation)
      embedder = described_class.for_embeddings(organisation, space: :configured)
      availability = organisation.ai_available_for?(:chat)

      aggregate_failures do
        # 1. what we tell the customer …
        expect(described_class.chat_provider_name(organisation)).to eq('openai_compatible')
        # 2. … is where the request goes (BY ID — ionos_standard is the provider's
        #    standard row and must never be the answer) …
        expect(chat.api_key).to eq(mistral_chat.access_token)
        expect(chat.api_base).to eq(mistral_chat.api_base)
        # 3. … and who is billed for it.
        expect(chat.billing_credential).to eq(mistral_chat)
        # 4. The embedding half is the package's whole triple (E11), verbatim.
        expect(described_class.embedding_space_for(organisation, space: :configured))
          .to eq(embedding_provider: 'openai_compatible', embedding_model: 'mistral-embed',
                 embedding_dims: 1024)
        expect(embedder.billing_credential).to eq(mistral_embed)
        # 5. The gate names the same provider the routing does — the drift
        #    doc/ki_provider_reichweite_plan.md §1.2 counts three incidents of.
        expect(availability).to be_available
        expect(availability.required_provider).to eq('openai_compatible')
        # 6. And a space built now would be pinned to the PACKAGE's credential,
        #    not to whatever active_for_provider answers later (§7b.2).
        expect(described_class.embedding_credentials_for(organisation)[:ai_credential_id])
          .to eq(mistral_embed.id)
      end
    end

    # An operator un-publishing a package is a CATALOGUE act, not a routing one:
    # `active` means "on offer" (§7b.1) and nothing else. An org already on the
    # package keeps running on it — the alternative, silently falling back to the
    # org's own columns, would move a customer's data into a different legal space
    # because someone tidied up the shop window.
    #
    # The consequence is stated in the deselection spec of Actors::SelectAiPackage:
    # until P4 that org cannot leave either, so withdrawal is a decision about NEW
    # customers only.
    it 'keeps routing an organisation whose package has been withdrawn from the catalogue' do
      put_on_package
      package.update_columns(active: false)

      expect(described_class.chat_provider_name(organisation.reload)).to eq('openai_compatible')
      expect(described_class.for_chat(organisation).api_key).to eq(mistral_chat.access_token)
      expect(described_class.embedding_space_for(organisation, space: :configured))
        .to eq(embedding_provider: 'openai_compatible', embedding_model: 'mistral-embed', embedding_dims: 1024)
    end

    # A curated package with no rungs at all is a DATA FAULT (AiPackage refuses to
    # publish one), so the only question is whether it fails loudly. It must not
    # answer off the org column: that would route a customer who picked an EU
    # package to whatever `ai_provider` still says, which is precisely the
    # plausible-looking wrong yes the package branch exists to prevent.
    describe 'a package that carries no rung at all' do
      let(:ladderless) do
        create(:ai_package, name: 'Ohne Stufen', embedding_credential: mistral_embed,
                            embedding_model: 'mistral-embed', embedding_dims: 1024)
      end

      before { organisation.update!(ai_package: ladderless, ai_provider: 'openai') }

      it 'names no provider rather than falling back to the org column' do
        expect(described_class.chat_provider_name(organisation)).to be_nil
      end

      it 'raises instead of building the org column’s provider' do
        expect { described_class.for_chat(organisation) }
          .to raise_error(Lalabase::Llm::Provider::Error, /Unknown LLM provider/)
      end

      # Gate and routing agree on the fault: the surface says "unsupported
      # provider" instead of offering a button that raises at the seam.
      it 'is refused by the gate for the same reason' do
        availability = organisation.ai_available_for?(:chat)

        expect(availability).not_to be_available
        expect(availability.reason).to eq(:unsupported_provider)
      end
    end

    # BUG (adversarial review 2026-08-02, P2): a package row whose
    # embedding_credential is NULL makes Factory#resolve_embedding_credentials
    # take the CURATED branch — `credential&.provider == provider_name` is
    # `nil == nil`, i.e. true — and #curated_embedding_resolution then calls
    # `enabled?` on nil. AiPackage's presence validation keeps `curated` rows out
    # of that state, but `kind: custom` rows are exempt from it by design, and
    # §7b.1 explicitly foresees seeding exactly such a row.
    #
    # Reached from AiPackage#embedding_switch_for?, whose rescue only catches
    # Provider::Error — so the NoMethodError escapes and the customer AI settings
    # page answers 500 (see the request spec of the same name).
    #
    # Pending rather than green: the expectation below states the behaviour the
    # seam promises everywhere else — a missing credential is a loud
    # MissingCredentialError, never a NoMethodError.
    it 'raises a MissingCredentialError, not a NoMethodError, for a package without an embedding credential' do
      credential_less = AiPackage.create!(kind: 'custom', name: 'Ohne Embedding-Zugang')

      expect { described_class.embedding_triple_for(organisation, package: credential_less) }
        .to raise_error(described_class::MissingCredentialError)
    end
  end
  # KI-Pakete P3 (doc/ki_pakete_plan.md §2.1, E2/E4): the Leistungsstufe governs
  # the paths the customer READS, and never the helper paths.
  #
  # The whole block runs on a package whose two rungs sit on DIFFERENT credential
  # rows. That is what makes the claim measurable: with one credential per
  # package the utility rung and the org rung differ only in a model string, and
  # a routing that ignored the flag entirely would still look plausible.
  describe 'utility routing (P3)' do
    let!(:mistral_fast) do
      create(:ai_credential, :openai_compatible, :eu_company,
             name: 'Mistral FR small', display_name: 'Mistral (EU)',
             default_model: 'mistral-small-latest', access_token: 'mistral-fast-token-123456')
    end

    let!(:mistral_thorough) do
      create(:ai_credential, :openai_compatible, :eu_company,
             name: 'Mistral FR large', display_name: 'Mistral Large (EU)',
             default_model: 'mistral-large-latest', access_token: 'mistral-thorough-token-1234')
    end

    let!(:mistral_embed) do
      create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
             name: 'Mistral FR embed', default_model: 'mistral-embed',
             access_token: 'mistral-embed-token-123')
    end

    let(:package) do
      package = create(:ai_package, name: 'Europäisch (zwei Stufen)', embedding_credential: mistral_embed,
                                    embedding_model: 'mistral-embed', embedding_dims: 1024)
      package.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0,
                            chat_credential: mistral_fast)
      package.tiers.create!(key: 'thorough', label: 'Gründlich', position: 1,
                            chat_credential: mistral_thorough)
      package
    end

    # THOROUGH on purpose: on the fast rung every routing answers alike and the
    # flag proves nothing.
    def org_on_thorough
      organisation.update!(ai_package: package, ai_package_tier_key: 'thorough',
                           ai_provider: 'openai', embedding_provider: 'openai')
      organisation
    end

    # The four utility rows of the registry (plus the chat half of
    # :repository_indexing, exercised separately below because it needs a lane).
    %i[ticket_summary document_summary meeting_participant_detection
       meeting_ticket_suggestions].each do |key|
      it "routes #{key} on the fast rung although the org chose thorough" do
        provider = described_class.for_feature(key, org_on_thorough)

        expect(provider.api_key).to eq('mistral-fast-token-123456')
        expect(provider.billing_credential).to eq(mistral_fast)
        expect(provider.default_chat_model).to eq('mistral-small-latest')
      end
    end

    # The counter-half, and the reason the flag is per row rather than per
    # service directory: two of the meetings services sit on the org's rung and
    # two helper paths beside them do not.
    %i[chat meeting_summary meeting_analysis ask_ai_post].each do |key|
      it "routes #{key} on the rung the org chose" do
        provider = described_class.for_feature(key, org_on_thorough)

        expect(provider.api_key).to eq('mistral-thorough-token-1234')
        expect(provider.billing_credential).to eq(mistral_thorough)
        expect(provider.default_chat_model).to eq('mistral-large-latest')
      end
    end

    it 'routes the chat half of repository_indexing on the fast rung' do
      provider = described_class.for_feature(:repository_indexing, org_on_thorough, lane: :chat)

      expect(provider.billing_credential).to eq(mistral_fast)
    end

    # for_chat is FEATURELESS and therefore always the org's rung: a caller that
    # names no feature cannot be a helper path, because "is this helper work?"
    # is a property of the registry row.
    it 'leaves .for_chat on the org rung' do
      expect(described_class.for_chat(org_on_thorough).billing_credential).to eq(mistral_thorough)
    end

    # The rung decides the PROVIDER too, not just the model — so the answer has
    # to travel as one decision. Split across two derivations, a provider_name
    # from one rung and credentials from the other would not raise: the tier
    # simply would not match and the org's own columns would take over.
    context 'with the two rungs on different providers' do
      let!(:anthropic_thorough) do
        create(:ai_credential, provider: 'anthropic', purpose: 'chat', region: 'us',
                               company_domicile: 'non_eu', embedding_cost_per_1m_cents: nil,
                               name: 'Claude', access_token: "sk-ant-#{'a' * 95}")
      end

      # Rung first, jurisdiction second: `non_eu` is a CLAIM the package checks
      # against its credentials, so it is only true once the US rung is in.
      before do
        package.tiers.find_by(key: 'thorough').update!(chat_credential: anthropic_thorough)
        package.tiers.reload
        package.update!(jurisdiction: 'non_eu')
      end

      it 'names the fast rung provider for a utility feature' do
        expect(described_class.chat_provider_name(org_on_thorough, utility: true)).to eq('openai_compatible')
        expect(described_class.chat_provider_name(organisation)).to eq('anthropic')
      end

      it 'builds the fast rung provider class for a utility feature' do
        expect(described_class.for_feature(:ticket_summary, org_on_thorough))
          .to be_a(Lalabase::Llm::OpenAiCompatibleProvider)
        expect(described_class.for_feature(:chat, organisation))
          .to be_a(Lalabase::Llm::AnthropicProvider)
      end
    end

    # A package predating the fast key, or one an operator built with a single
    # rung. Answering "no rung" here would take a working helper path off chat
    # to save money on it.
    context 'when the package carries no fast rung' do
      # reload, or the in-memory association still holds the destroyed rung and
      # the example passes for the wrong reason.
      before do
        package.tiers.find_by(key: 'fast').destroy!
        package.tiers.reload
      end

      it 'falls back to the lowest rung the package does offer' do
        provider = described_class.for_feature(:ticket_summary, org_on_thorough)

        expect(provider.billing_credential).to eq(mistral_thorough)
      end
    end

    # THE neutrality claim of P3 (DoD): an org without a curated package has no
    # ladder, so a utility row must route exactly as it did before the flag
    # existed — the same credential the org's own chat lane resolves.
    context 'for an organisation without a package (NULL / custom)' do
      let!(:openai_standard) { create(:ai_credential, :active, provider: 'openai') }

      it 'inherits the chat credential, exactly like for_chat' do
        expect(organisation.ai_package_id).to be_nil

        utility = described_class.for_feature(:ticket_summary, organisation)
        chat = described_class.for_chat(organisation)

        expect(utility.billing_credential).to eq(openai_standard)
        expect(utility.billing_credential).to eq(chat.billing_credential)
        expect(utility.default_chat_model).to eq(chat.default_chat_model)
      end

      it 'inherits the BYOK token too' do
        organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-org-own-key-123456789')

        provider = described_class.for_feature(:document_summary, organisation)

        expect(provider.api_key).to eq('sk-org-own-key-123456789')
        expect(provider.billing_credential).to be_nil
      end
    end
  end
end
