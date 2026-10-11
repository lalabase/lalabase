# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_credentials
#
#  id                          :uuid             not null, primary key
#  access_token                :text             not null
#  active                      :boolean          default(FALSE)
#  additional_config           :json
#  api_base                    :string
#  company_domicile            :string
#  default_model               :string
#  description                 :text
#  display_name                :string
#  embedding_cost_per_1m_cents :integer
#  enabled                     :boolean          default(TRUE)
#  included_in_quota           :boolean          default(FALSE), not null
#  input_cost_per_1m_cents     :integer
#  name                        :string           not null
#  output_cost_per_1m_cents    :integer
#  provider                    :string           default("openai"), not null
#  purpose                     :string           default("both"), not null
#  region                      :string
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  organization_id             :string
#
# Indexes
#
#  index_ai_credentials_on_active               (active)
#  index_ai_credentials_on_enabled              (enabled)
#  index_ai_credentials_on_provider             (provider)
#  index_ai_credentials_on_provider_and_active  (provider,active) UNIQUE WHERE (active = true)
#
require 'rails_helper'

RSpec.describe AiCredential, type: :model do
  # ============================================================
  # Constants
  # ============================================================
  describe 'constants' do
    it 'defines PROVIDERS as frozen array (cohere removed in S1 — never functional)' do
      expect(described_class::PROVIDERS).to eq(%w[openai anthropic google openai_compatible])
      expect(described_class::PROVIDERS).to be_frozen
    end

    it 'defines PROVIDER_DISPLAY_NAMES for all providers' do
      described_class::PROVIDERS.each do |provider|
        expect(described_class::PROVIDER_DISPLAY_NAMES).to have_key(provider)
      end
      expect(described_class::PROVIDER_DISPLAY_NAMES).to be_frozen
    end

    it 'defines MASKED_TOKEN_PREFIXES for all providers' do
      described_class::PROVIDERS.each do |provider|
        expect(described_class::MASKED_TOKEN_PREFIXES).to have_key(provider)
      end
      expect(described_class::MASKED_TOKEN_PREFIXES).to be_frozen
    end
  end

  # ============================================================
  # Validations
  # ============================================================
  describe 'validations' do
    subject { build(:ai_credential) }

    describe 'name' do
      it { is_expected.to validate_presence_of(:name) }
      it { is_expected.to validate_uniqueness_of(:name) }

      it 'rejects duplicate names' do
        create(:ai_credential, name: 'Duplicate Name')
        duplicate = build(:ai_credential, name: 'Duplicate Name')
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:name]).to be_present
      end
    end

    describe 'provider' do
      it { is_expected.to validate_presence_of(:provider) }

      # Whitelist-positive iteration over the ONE source of truth: every provider
      # the Factory can build must be creatable — a new Factory registration
      # (e.g. google in Slice 3) becomes selectable without touching this spec.
      it 'accepts every implemented provider' do
        described_class.implemented_providers.each do |provider|
          credential = build(:ai_credential, provider: provider, purpose: 'chat')
          # Providers with a token-format rule need a conforming token
          credential.access_token = "sk-ant-#{'a' * 95}" if provider == 'anthropic'
          credential.access_token = build(:ai_credential, :google).access_token if provider == 'google'
          expect(credential).to be_valid, "Expected provider '#{provider}' to be valid"
        end
      end

      it 'rejects invalid providers' do
        %w[azure mistral invalid].each do |provider|
          credential = build(:ai_credential, provider: provider)
          expect(credential).not_to be_valid, "Expected provider '#{provider}' to be invalid"
          expect(credential.errors[:provider]).to be_present
        end
      end

      it 'rejects blank provider' do
        credential = build(:ai_credential, provider: '')
        expect(credential).not_to be_valid
      end
    end

    describe 'access_token' do
      it { is_expected.to validate_presence_of(:access_token) }

      it 'rejects nil access_token' do
        credential = build(:ai_credential, access_token: nil)
        expect(credential).not_to be_valid
        expect(credential.errors[:access_token]).to be_present
      end
    end

    describe 'default_model' do
      it { is_expected.to validate_presence_of(:default_model) }
    end

    describe 'active uniqueness per provider' do
      it 'allows multiple inactive credentials for the same provider' do
        create(:ai_credential, provider: 'openai', active: false)
        second = build(:ai_credential, provider: 'openai', active: false)
        expect(second).to be_valid
      end

      it 'allows one active credential per provider' do
        create(:ai_credential, :active, provider: 'openai')
        second = build(:ai_credential, :active, provider: 'openai')
        expect(second).not_to be_valid
        expect(second.errors[:active]).to be_present
      end

      it 'allows active credentials for different providers' do
        create(:ai_credential, :active, provider: 'openai')
        second = build(:ai_credential, :active, :anthropic)
        expect(second).to be_valid
      end

      it 'skips uniqueness check when not active' do
        create(:ai_credential, :active, provider: 'openai')
        inactive = build(:ai_credential, provider: 'openai', active: false)
        expect(inactive).to be_valid
      end
    end

    describe 'access_token format' do
      context 'with anthropic provider' do
        it 'rejects token with wrong prefix' do
          credential = build(:ai_credential, :anthropic, access_token: 'wrong-prefix-token')
          expect(credential).not_to be_valid
          expect(credential.errors[:access_token]).to be_present
        end

        it 'rejects token that is too short' do
          credential = build(:ai_credential, :anthropic, access_token: 'sk-ant-tooshort')
          expect(credential).not_to be_valid
        end

        it 'accepts valid anthropic token' do
          valid_token = "sk-ant-#{'a' * 95}"
          credential = build(:ai_credential, :anthropic, access_token: valid_token)
          expect(credential).to be_valid
        end

        it 'accepts anthropic token with hyphens and underscores' do
          valid_token = "sk-ant-#{'a-b_c' * 19}"
          credential = build(:ai_credential, :anthropic, access_token: valid_token)
          expect(credential).to be_valid
        end
      end

      context 'with openai provider' do
        it 'accepts any non-blank token' do
          credential = build(:ai_credential, provider: 'openai', access_token: 'any-token')
          expect(credential).to be_valid
        end
      end

      context 'with openai_compatible provider' do
        it 'accepts any non-blank token (no format rule for this provider)' do
          credential = build(:ai_credential, provider: 'openai_compatible', access_token: 'any-token')
          expect(credential).to be_valid
        end
      end

      # Google SA-JSON rule (GoogleVertexProvider slice): Vertex auth is
      # service-account-only — an API key would silently use the GLOBAL
      # endpoint and void EU data residency. Validated at write time so a
      # broken credential fails at save, not at the first call. Twin block in
      # the Admin::AiCredential spec (shared concern = the real write path).
      context 'with google provider' do
        it 'accepts a parseable SA JSON with private_key and client_email (factory trait)' do
          expect(build(:ai_credential, :google)).to be_valid
        end

        it 'rejects a legacy AIza… API key (not JSON)' do
          credential = build(:ai_credential, :google, access_token: 'AIzaSyLegacyKey123')
          expect(credential).not_to be_valid
          expect(credential.errors[:access_token]).to be_present
        end

        %w[private_key client_email].each do |missing_key|
          it "rejects an SA JSON missing #{missing_key}" do
            json = JSON.parse(build(:ai_credential, :google).access_token).except(missing_key).to_json
            credential = build(:ai_credential, :google, access_token: json)
            expect(credential).not_to be_valid
            expect(credential.errors[:access_token]).to be_present
          end
        end

        it 'rejects a JSON that is not an object' do
          credential = build(:ai_credential, :google, access_token: '["private_key","client_email"]')
          expect(credential).not_to be_valid
          expect(credential.errors[:access_token]).to be_present
        end

        it 'does not brick a facade-era google row (AIza key) on unrelated edits' do
          legacy = create(:ai_credential)
          legacy.update_column(:provider, 'google') # simulate the pre-slice row, token untouched
          legacy.reload
          expect(legacy.update(description: 'still editable')).to be(true)
        end

        it 'fires when the token itself is changed on such a legacy row' do
          legacy = create(:ai_credential)
          legacy.update_column(:provider, 'google')
          legacy.reload
          expect(legacy.update(access_token: 'AIzaSyNewKey')).to be(false)
          expect(legacy.errors[:access_token]).to be_present
        end
      end

      context 'when access_token is blank' do
        it 'skips format validation (presence catches it)' do
          credential = build(:ai_credential, :anthropic, access_token: nil)
          expect(credential).not_to be_valid
          expect(credential.errors[:access_token]).to be_present
        end
      end
    end
  end

  # ============================================================
  # Provider rules (S1 "honest facade", shared concern
  # AiCredentialProviderRules — see the twin block in the Admin::AiCredential
  # spec pinning the same rules on the actual admin write path).
  # Intent: a credential must never promise what Lalabase::Llm::Factory cannot
  # deliver — unimplemented providers are not selectable or activatable, and
  # purpose may only include embeddings when the provider class supports them.
  # ============================================================
  describe '.implemented_providers' do
    it 'derives from the Factory registry (the ONE source of truth)' do
      expect(described_class.implemented_providers)
        .to eq(Lalabase::Llm::Factory::PROVIDER_CLASSES.keys)
    end

    it 'pins the current set — google joined with the GoogleVertexProvider slice' do
      expect(described_class.implemented_providers)
        .to contain_exactly('openai', 'anthropic', 'openai_compatible', 'google')
    end

    it 'is a subset of PROVIDERS (every implemented provider stays displayable)' do
      expect(described_class.implemented_providers - described_class::PROVIDERS).to be_empty
    end
  end

  describe 'provider implementation rule' do
    it 'rejects removed and made-up providers on create' do
      %w[cohere made_up_llm].each do |provider|
        credential = build(:ai_credential, provider: provider)
        expect(credential).not_to be_valid, "Expected provider '#{provider}' to be invalid"
        expect(credential.errors[:provider]).to be_present
      end
    end

    context 'with an existing legacy row (removed provider cohere)' do
      let(:legacy) do
        create(:ai_credential).tap do |credential|
          # Bypass validations to simulate a pre-S1 row.
          credential.update_column(:provider, 'cohere')
          credential.reload
        end
      end

      it 'is frozen for edits — cohere left PROVIDERS entirely, so the base inclusion bites on any save' do
        expect(legacy.update(description: 'no longer editable')).to be(false)
        expect(legacy.errors[:provider]).to be_present
      end

      it 'stays destroyable' do
        expect(legacy.destroy).to be_truthy
      end

      it 'can be migrated TO an implemented provider' do
        expect(legacy.update(provider: 'openai')).to be(true)
      end

      it 'cannot be switched to another unimplemented provider' do
        legacy_openai = create(:ai_credential)
        expect(legacy_openai.update(provider: 'cohere')).to be(false)
        expect(legacy_openai.errors[:provider]).to be_present
      end
    end

    # The "listed in PROVIDERS but not implemented" situation (google before
    # this slice) no longer occurs with a real value — simulate it to keep the
    # concern's conditionality (rules fire only on selection CHANGE) pinned.
    it 'tolerates a displayable-but-unimplemented provider on unrelated edits (rule fires on change only)' do
      credential = create(:ai_credential)
      credential.update_column(:provider, 'google')
      credential.reload
      allow(described_class).to receive(:implemented_providers)
        .and_return(%w[openai anthropic openai_compatible])

      expect(credential.update(description: 'still editable')).to be(true)
    end
  end

  describe 'purpose capability rule' do
    # Matrix: provider x purpose. Anthropic has no embedding model — the
    # facade used to let purpose embedding/both through and fail at runtime
    # (NotSupportedError), far away from the cause.
    it 'rejects embedding purposes for anthropic (no embedding capability)' do
      %w[embedding both].each do |purpose|
        credential = build(:ai_credential, :anthropic, purpose: purpose,
                                                       embedding_cost_per_1m_cents: 2)
        expect(credential).not_to be_valid, "Expected anthropic + #{purpose} to be invalid"
        expect(credential.errors[:purpose]).to be_present
      end
    end

    it 'accepts chat purpose for anthropic' do
      expect(build(:ai_credential, :anthropic, purpose: 'chat')).to be_valid
    end

    it 'accepts every purpose for embedding-capable providers (openai, openai_compatible)' do
      %w[openai openai_compatible].each do |provider|
        AiCredentialPricing::PURPOSES.each do |purpose|
          credential = build(:ai_credential, provider: provider, purpose: purpose)
          expect(credential).to be_valid, "Expected #{provider} + #{purpose} to be valid"
        end
      end
    end

    it 'accepts every purpose for google (embedding-capable via the 1536-truncated gemini-embedding-001)' do
      AiCredentialPricing::PURPOSES.each do |purpose|
        credential = build(:ai_credential, :google, purpose: purpose)
        expect(credential).to be_valid, "Expected google + #{purpose} to be valid"
      end
    end

    it 'does not brick a legacy anthropic/both row on unrelated edits (rule fires on purpose/provider change)' do
      legacy = create(:ai_credential, :anthropic)
      legacy.update_column(:purpose, 'both')
      legacy.reload
      expect(legacy.update(description: 'still editable')).to be(true)
      expect(legacy.update(purpose: 'both')).to be(true) # no-op change stays quiet
      legacy.purpose = 'embedding'
      expect(legacy).not_to be_valid
    end
  end

  describe 'activation rule' do
    it 'refuses to activate a legacy row with an unimplemented provider' do
      legacy = create(:ai_credential)
      legacy.update_column(:provider, 'cohere')
      legacy.reload

      expect(legacy.update(active: true)).to be(false)
      expect(legacy.errors[:active]).to be_present
    end

    it 'refuses activation via .activate! as well (update! path)' do
      legacy = create(:ai_credential)
      legacy.update_column(:provider, 'cohere')

      expect { described_class.activate!(legacy.id) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(legacy.reload.active).to be(false)
    end

    it 'leaves an already-active legacy row editable (rule fires on the active flip only)' do
      credential = create(:ai_credential, :active)
      credential.update_column(:provider, 'google')
      credential.reload
      # Simulate the PROVIDERS-listed-but-unimplemented situation (see above) —
      # cohere would trip the base inclusion, masking the activation rule.
      allow(described_class).to receive(:implemented_providers)
        .and_return(%w[openai anthropic openai_compatible])

      expect(credential.update(description: 'still editable')).to be(true)
    end

    it 'activates implemented providers as before' do
      credential = create(:ai_credential, provider: 'openai', active: false)
      expect(credential.update(active: true)).to be(true)
    end

    it 'activates a google credential (implemented since the GoogleVertexProvider slice)' do
      credential = create(:ai_credential, :google, active: false)
      expect(credential.update(active: true)).to be(true)
    end
  end

  describe '.provider_options_for_select' do
    it 'offers exactly the implemented providers with their display names' do
      expect(described_class.provider_options_for_select).to eq(
        described_class.implemented_providers.map do |provider|
          [described_class::PROVIDER_DISPLAY_NAMES.fetch(provider), provider]
        end
      )
    end

    it 'does not offer the removed cohere provider' do
      values = described_class.provider_options_for_select.map(&:last)
      expect(values).not_to include('cohere')
    end

    it 'offers google as a regular implemented provider (Slice 3 — the facade fell with the Factory registration)' do
      expect(described_class.provider_options_for_select).to include(['Google (Gemini)', 'google'])
    end

    it "re-adds an edit form's current legacy provider (capitalized fallback label) so the selection is not silently switched" do
      options = described_class.provider_options_for_select(current: 'cohere')
      expect(options).to include(%w[Cohere cohere])
    end

    it 'does not duplicate an implemented current provider' do
      options = described_class.provider_options_for_select(current: 'openai')
      expect(options.map(&:last).count('openai')).to eq(1)
    end
  end

  # ============================================================
  # EU chat presets (S2) — pinned against the schema: every preset must build
  # a VALID openai_compatible credential, so a preset can never silently drift
  # away from the model (renamed column, new required field, capability rule).
  # ============================================================
  describe 'EU_CHAT_PRESETS' do
    it 'is frozen data' do
      expect(described_class::EU_CHAT_PRESETS).to be_frozen
    end

    it 'builds a valid openai_compatible credential from every preset' do
      described_class::EU_CHAT_PRESETS.each do |key, preset|
        credential = build(:ai_credential, :not_metered,
                           provider: 'openai_compatible',
                           access_token: 'eu-preset-test-token',
                           **preset)
        expect(credential).to be_valid,
                              "Expected preset '#{key}' to build a valid credential, " \
                              "got: #{credential.errors.full_messages.join(', ')}"
      end
    end

    # The REASON changed with embedding v2 PR 5, the expectation did not: 1024-dim
    # spaces are configurable now (own storage lane + ANN index on the sidecar), so
    # these presets stay chat-only purely by scope decision. Extending them to
    # embedding purposes is a follow-up to PR 6 (pointer + staged switch) — until
    # then, picking such a preset would trigger a hard space switch without a net.
    it 'stays chat-only (embedding presets are a PR-6 follow-up, no longer a storage limit)' do
      described_class::EU_CHAT_PRESETS.each do |key, preset|
        expect(preset[:purpose]).to eq('chat'), "Expected preset '#{key}' to be chat-only"
      end
    end

    it 'declares an EU region and an https endpoint for every preset' do
      described_class::EU_CHAT_PRESETS.each do |key, preset|
        expect(preset[:region]).to eq('eu'), "Expected preset '#{key}' to declare region eu"
        expect(preset[:api_base]).to start_with('https://'), "Expected preset '#{key}' to use https"
        expect(preset[:display_name]).to be_present
        expect(preset[:default_model]).to be_present
      end
    end

    # A '-latest' alias rolls over to a new model version on the PROVIDER's
    # schedule, so the usual defence — verify the name against provider docs
    # before prod — cannot catch it: the name is still correct at check time and
    # wrong later. What breaks is silent and threefold: the per-1M prices sit on
    # the credential (a metered row would bill the new model at the old model's
    # price), the Art. 13 notice names a model that no longer answers, and the
    # package promises a model class that changed under the customer. Pinning is
    # therefore a property of the preset data, not a reviewer's habit.
    it 'pins every preset to an explicit model version, never a -latest alias' do
      described_class::EU_CHAT_PRESETS.each do |key, preset|
        expect(preset[:default_model]).not_to end_with('-latest'),
                                              "Expected preset '#{key}' to pin its model, " \
                                              "got the rolling alias '#{preset[:default_model]}'"
      end
    end

    # E12: region and company seat are two independent facts, and the preset is
    # the ONLY place that knows the second one — all three run under the provider
    # name 'openai_compatible', so nothing about the saved row could answer it
    # afterwards (§3.4, why a provider-name list was rejected as a solution).
    it 'declares an EU company seat for every preset, not just an EU region' do
      described_class::EU_CHAT_PRESETS.each do |key, preset|
        expect(preset[:company_domicile]).to eq('eu'), "Expected preset '#{key}' to declare an EU company seat"
      end
    end

    # A preset is a starting aid, and it must carry the fact all the way into the
    # row — a preset that only decorated the form would leave the axis empty.
    it 'produces a credential whose seat an eu_native package can rely on' do
      preset = described_class::EU_CHAT_PRESETS.fetch('mistral')
      credential = create(:ai_credential, :not_metered, provider: 'openai_compatible',
                                                        access_token: 'eu-preset-test-token', **preset)

      expect(credential.reload.company_domicile).to eq('eu')
      expect(build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential).eu_company?).to be(true)
    end
  end

  # E12 (§3.3): the company-seat axis. NULL stays a first-class state — the
  # column is new, every row written before it is unclassified, and a package
  # claim degrades to a warning there rather than blocking.
  describe 'company_domicile' do
    it 'accepts the two recorded values and blank' do
      expect(build(:ai_credential, company_domicile: 'eu')).to be_valid
      expect(build(:ai_credential, company_domicile: 'non_eu')).to be_valid
      expect(build(:ai_credential, company_domicile: nil)).to be_valid
      # The admin select carries an empty option, so "" must read as "not
      # recorded" rather than as an invalid value.
      expect(build(:ai_credential, company_domicile: '')).to be_valid
    end

    it 'rejects an invented value' do
      credential = build(:ai_credential, company_domicile: 'maybe_eu')
      credential.validate

      expect(credential.errors.details[:company_domicile].map { |d| d[:error] }).to include(:inclusion)
    end
  end

  # ============================================================
  # Purpose + quota price guard (S2)
  # Intent: a metered (included_in_quota) credential can never exist without the
  # prices CostCalculator bills it at — purpose-aware, so only the price fields it
  # actually uses are required. This is what keeps S3 metering from silently
  # billing a system credential at 0.
  # ============================================================
  describe 'purpose' do
    it 'accepts every value in the PURPOSES whitelist (iterates the constant, not literals)' do
      described_class::PURPOSES.each do |p|
        expect(build(:ai_credential, purpose: p)).to be_valid, "expected purpose #{p.inspect} to be valid"
      end
    end

    it 'pins the whitelist to exactly [chat, embedding, both] (shrinking it must break a test)' do
      expect(described_class::PURPOSES).to eq(%w[chat embedding both])
    end

    it 'rejects an unknown purpose' do
      credential = build(:ai_credential, purpose: 'vision')
      expect(credential).not_to be_valid
      expect(credential.errors[:purpose]).to be_present
    end
  end

  describe 'quota price guard' do
    it 'is valid when a quota credential carries all relevant prices' do
      expect(build(:ai_credential, purpose: 'both')).to be_valid
    end

    it 'is invalid when a quota chat credential lacks its INPUT price' do
      credential = build(:ai_credential, :chat_only, input_cost_per_1m_cents: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:input_cost_per_1m_cents]).to be_present
    end

    it 'is invalid when a quota chat credential lacks its OUTPUT price' do
      # Separate from the input case — kills a mutation that only checks the input price.
      credential = build(:ai_credential, :chat_only, output_cost_per_1m_cents: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:output_cost_per_1m_cents]).to be_present
    end

    it 'requires the embedding price for an embedding-purpose credential' do
      credential = build(:ai_credential, :embedding_only, embedding_cost_per_1m_cents: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:embedding_cost_per_1m_cents]).to be_present
    end

    it 'does NOT require chat prices for an embedding-purpose credential (branch is purpose-aware)' do
      # :embedding_only already nils input+output; embedding price present ⇒ still valid.
      expect(build(:ai_credential, :embedding_only)).to be_valid
    end

    it 'does NOT require the embedding price for a chat-purpose credential' do
      expect(build(:ai_credential, :chat_only, embedding_cost_per_1m_cents: nil)).to be_valid
    end

    it "requires ALL three prices when purpose is 'both'" do
      credential = build(:ai_credential, purpose: 'both', embedding_cost_per_1m_cents: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:embedding_cost_per_1m_cents]).to be_present
    end

    it 'skips the guard entirely for non-metered credentials' do
      expect(build(:ai_credential, :without_prices, included_in_quota: false)).to be_valid
    end

    it 'treats a zero price as missing (boundary: strictly > 0, not >= 0)' do
      credential = build(:ai_credential, :chat_only, input_cost_per_1m_cents: 0)
      expect(credential).not_to be_valid
      expect(credential.errors[:input_cost_per_1m_cents]).to be_present
    end
  end

  describe 'column defaults (contract — asserted WITHOUT the factory)' do
    # Category 4: the factory sets included_in_quota=true + prices, so we must use a bare
    # .new to test the MIGRATION defaults. included_in_quota=false was a deliberate S2
    # decision (existing un-priced credentials stay valid under the guard) — flipping the
    # migration default back to true must break here.
    it 'defaults included_in_quota to false and purpose to "both" on a bare instance' do
      fresh = described_class.new
      expect(fresh.included_in_quota).to be(false)
      expect(fresh.purpose).to eq('both')
    end
  end

  # ============================================================
  # Cache invalidation on write (S2 fix)
  # Intent: active_for_provider caches for 5 min; ANY write — not just active
  # flips — must drop the key, so an admin price edit takes effect immediately.
  # ============================================================
  describe 'active_for_provider cache invalidation' do
    # Store-independent: assert the key is dropped, so the test holds whether the
    # test cache is a real store or the null store.
    it 'clears the cache on a NON-active-field edit (the old guard only fired on active flips)' do
      credential = create(:ai_credential, :active, provider: 'openai')

      expect(Rails.cache).to receive(:delete).with('active_ai_credential_openai').at_least(:once)
      credential.update!(input_cost_per_1m_cents: 99)
    end

    it 'clears the cache on create' do
      expect(Rails.cache).to receive(:delete).with('active_ai_credential_openai').at_least(:once)
      create(:ai_credential, provider: 'openai')
    end

    it 'clears the cache on destroy' do
      credential = create(:ai_credential, provider: 'openai', active: false)
      expect(Rails.cache).to receive(:delete).with('active_ai_credential_openai').at_least(:once)
      credential.destroy
    end
  end

  # ============================================================
  # Encryption
  # ============================================================
  describe 'encryption' do
    it 'encrypts access_token' do
      credential = create(:ai_credential, access_token: 'sk-secret-key-12345')
      # Reload from DB to ensure encryption roundtrip works
      reloaded = described_class.find(credential.id)
      expect(reloaded.access_token).to eq('sk-secret-key-12345')
    end
  end

  # ============================================================
  # Associations
  # ============================================================
  describe 'associations' do
    it { is_expected.to have_many(:ai_usages).dependent(:nullify) }
  end

  # ============================================================
  # Scopes
  # ============================================================
  describe 'scopes' do
    describe '.active' do
      it 'returns only active credentials' do
        active = create(:ai_credential, :active)
        _inactive = create(:ai_credential, active: false, region: 'eu')

        expect(described_class.active).to contain_exactly(active)
      end

      it 'returns empty when none active' do
        create(:ai_credential, active: false, region: 'eu')
        expect(described_class.active).to be_empty
      end
    end

    describe '.enabled' do
      it 'returns only enabled credentials' do
        enabled = create(:ai_credential, enabled: true)
        _disabled = create(:ai_credential, :disabled)

        expect(described_class.enabled).to contain_exactly(enabled)
      end
    end

    describe '.for_provider' do
      it 'filters by provider' do
        openai = create(:ai_credential, provider: 'openai')
        _anthropic = create(:ai_credential, :anthropic)

        expect(described_class.for_provider('openai')).to contain_exactly(openai)
      end

      it 'returns empty for nonexistent provider' do
        create(:ai_credential, provider: 'openai')
        expect(described_class.for_provider('anthropic')).to be_empty
      end
    end

    describe 'scope chaining' do
      it 'chains active + for_provider' do
        active_openai = create(:ai_credential, :active, provider: 'openai')
        _inactive_openai = create(:ai_credential, provider: 'openai', active: false)
        _active_anthropic = create(:ai_credential, :active, :anthropic)

        result = described_class.active.for_provider('openai')
        expect(result).to contain_exactly(active_openai)
      end
    end
  end

  # ============================================================
  # Class Methods
  # ============================================================
  describe '.active_for_provider' do
    it 'returns active credential for given provider' do
      active = create(:ai_credential, :active, provider: 'openai')
      _inactive = create(:ai_credential, provider: 'openai', active: false)

      expect(described_class.active_for_provider('openai')).to eq(active)
    end

    it 'returns nil when no active credential exists' do
      create(:ai_credential, provider: 'openai', active: false)
      expect(described_class.active_for_provider('openai')).to be_nil
    end

    it 'defaults to openai provider' do
      active = create(:ai_credential, :active, provider: 'openai')
      expect(described_class.active_for_provider).to eq(active)
    end

    it 'caches the result' do
      create(:ai_credential, :active, provider: 'openai')

      # First call hits DB
      described_class.active_for_provider('openai')
      # Second call should use cache
      expect(Rails.cache).to receive(:fetch)
        .with('active_ai_credential_openai', expires_in: 5.minutes)
        .and_call_original

      described_class.active_for_provider('openai')
    end

    it 'reads through the SAME concern key it is invalidated by (read/clear cannot drift)' do
      create(:ai_credential, :active, provider: 'openai')
      # Binds the READ key to AiCredentialCacheable.cache_key_for — the concern uses the
      # same method to CLEAR. If one side hardcodes a divergent key, this breaks.
      expect(Rails.cache).to receive(:fetch)
        .with(AiCredentialCacheable.cache_key_for('openai'), expires_in: 5.minutes)
        .and_call_original
      described_class.active_for_provider('openai')
    end

    it 'uses separate cache keys per provider' do
      create(:ai_credential, :active, provider: 'openai')
      create(:ai_credential, :active, :anthropic)

      openai = described_class.active_for_provider('openai')
      anthropic = described_class.active_for_provider('anthropic')

      expect(openai.provider).to eq('openai')
      expect(anthropic.provider).to eq('anthropic')
    end
  end

  describe '.activate!' do
    it 'activates the specified credential' do
      credential = create(:ai_credential, active: false, region: 'eu')

      described_class.activate!(credential.id)

      expect(credential.reload).to be_active
    end

    it 'deactivates other credentials of the same provider' do
      old_active = create(:ai_credential, :active, provider: 'openai')
      new_credential = create(:ai_credential, provider: 'openai', active: false)

      described_class.activate!(new_credential.id)

      expect(old_active.reload).not_to be_active
      expect(new_credential.reload).to be_active
    end

    it 'does not affect credentials of other providers' do
      anthropic_active = create(:ai_credential, :active, :anthropic)
      openai_credential = create(:ai_credential, provider: 'openai', active: false)

      described_class.activate!(openai_credential.id)

      expect(anthropic_active.reload).to be_active
    end

    it 'raises RecordNotFound for nonexistent ID' do
      expect do
        described_class.activate!(SecureRandom.uuid)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'logs activation' do
      credential = create(:ai_credential, active: false, region: 'eu')

      expect(Rails.logger).to receive(:info).with(
        a_string_matching(/#{credential.name}.*#{credential.provider}.*activated/)
      )

      described_class.activate!(credential.id)
    end

    it 'wraps in a transaction' do
      credential = create(:ai_credential, active: false, region: 'eu')

      # Simulate a validation failure after deactivation
      allow_any_instance_of(described_class).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      expect do
        described_class.activate!(credential.id)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # .with_failover was removed in KI-Pakete P0 (no production caller — the specs
  # here were its only usage; see the note in the model).

  describe '.providers' do
    it 'returns the PROVIDERS constant' do
      expect(described_class.providers).to eq(described_class::PROVIDERS)
    end
  end

  describe '.provider_display_names' do
    it 'returns the PROVIDER_DISPLAY_NAMES constant' do
      expect(described_class.provider_display_names).to eq(described_class::PROVIDER_DISPLAY_NAMES)
    end
  end

  # ============================================================
  # Instance Methods
  # ============================================================
  describe '#masked_token' do
    it 'returns nil when access_token is nil' do
      credential = build(:ai_credential, access_token: nil)
      # bypass validation
      credential.define_singleton_method(:access_token) { nil }
      expect(credential.masked_token).to be_nil
    end

    it 'returns nil when access_token is blank' do
      credential = build(:ai_credential)
      credential.define_singleton_method(:access_token) { '' }
      expect(credential.masked_token).to be_nil
    end

    it 'masks openai token with sk- prefix' do
      credential = build(:ai_credential, provider: 'openai', access_token: 'sk-1234567890abcdef')
      masked = credential.masked_token
      expect(masked).to start_with('sk-')
      expect(masked).to include('*')
      expect(masked).to end_with(credential.access_token.last([credential.access_token.length / 4, 8].min))
    end

    it 'masks anthropic token with sk-ant- prefix' do
      token = "sk-ant-#{'a' * 95}"
      credential = build(:ai_credential, provider: 'anthropic', access_token: token)
      masked = credential.masked_token
      expect(masked).to start_with('sk-ant-')
      expect(masked).to include('*')
    end

    it 'masks the google service-account JSON in full (no prefix — it is not an AIza key)' do
      credential = build(:ai_credential, :google)
      masked = credential.masked_token
      expect(masked).to start_with('*')
      expect(masked).not_to include('private_key')
    end

    it 'masks openai_compatible token without prefix' do
      credential = build(:ai_credential, provider: 'openai_compatible', access_token: 'compat-token-123456')
      masked = credential.masked_token
      expect(masked).to include('*')
      expect(masked).to end_with(credential.access_token.last([credential.access_token.length / 4, 8].min))
    end

    it 'handles very short tokens gracefully' do
      credential = build(:ai_credential, provider: 'openai', access_token: 'ab')
      masked = credential.masked_token
      # prefix "sk-" is 3 chars, token is 2 chars. mask_length becomes 0.
      expect(masked).not_to be_nil
    end

    it 'caps suffix at 8 characters' do
      long_token = 'sk-' + 'x' * 200
      credential = build(:ai_credential, provider: 'openai', access_token: long_token)
      masked = credential.masked_token
      # suffix_length = min(203/4, 8) = 8
      visible_suffix = long_token.last(8)
      expect(masked).to end_with(visible_suffix)
    end

    it 'uses empty prefix for unknown provider' do
      credential = build(:ai_credential, provider: 'openai', access_token: 'some-token')
      # Force unknown provider without validation
      credential.define_singleton_method(:provider) { 'unknown' }
      masked = credential.masked_token
      expect(masked).to include('*')
    end
  end

  # #client_instance is gone together with the per-model #test_connection it
  # backed — the last ungated vendor-client constructor outside the providers.
  # Its guard-allowlist entry went with it (direct_client_guard_spec).

  describe '#provider_display_name' do
    it 'returns display name for known providers' do
      {
        'openai' => 'OpenAI (GPT)',
        'anthropic' => 'Anthropic (Claude)',
        'google' => 'Google (Gemini)',
        'openai_compatible' => 'OpenAI-kompatibel (eigener Endpunkt)'
      }.each do |provider, display_name|
        credential = build(:ai_credential, provider: provider)
        expect(credential.provider_display_name).to eq(display_name)
      end
    end

    it 'falls back to capitalized provider name for unknown providers' do
      credential = build(:ai_credential, provider: 'openai')
      credential.define_singleton_method(:provider) { 'mystery' }
      expect(credential.provider_display_name).to eq('Mystery')
    end
  end

  # Since AiCredentialConnectivity EVERY implemented provider is probed for real
  # via Provider#connectivity_check. Before, only 'openai' made an actual call;
  # every other provider fell through to `access_token.present?`, so the "test
  # connection" button reported success for a credential that could not connect
  # at all. The anthropic and openai_compatible examples below are the
  # regression guards for exactly that.
  describe '#test_connection' do
    # Replaces the provider class the credential routes to, so nothing goes out
    # over the wire. instance_double verifies connectivity_check really exists.
    def stub_probe(klass, **kwargs)
      instance_double(klass, **kwargs).tap do |probe|
        allow(klass).to receive(:new).and_return(probe)
      end
    end

    it 'returns false when disabled, without building a provider' do
      credential = create(:ai_credential, :disabled)
      allow(Lalabase::Llm::OpenAiProvider).to receive(:new)

      expect(credential.test_connection).to be false
      expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
    end

    it 'is true when the probe round-trips' do
      credential = create(:ai_credential, :active, provider: 'openai')
      stub_probe(Lalabase::Llm::OpenAiProvider, connectivity_check: true)

      expect(credential.test_connection).to be true
    end

    it 'is false when the probe fails' do
      credential = create(:ai_credential, :active, provider: 'openai')
      stub_probe(Lalabase::Llm::OpenAiProvider, connectivity_check: false)

      expect(credential.test_connection).to be false
    end

    # Pins the DELEGATION (this model asks the provider and honours its answer);
    # that the anthropic probe itself is real is pinned one layer down, in
    # spec/services/lalabase/llm/anthropic_provider_spec.rb — both were
    # `access_token.present?` before, so one without the other proves nothing.
    it 'honours a failing anthropic probe instead of trusting token presence' do
      credential = create(:ai_credential, :anthropic)
      stub_probe(Lalabase::Llm::AnthropicProvider, connectivity_check: false)

      expect(credential.test_connection).to be false
    end

    context 'with an openai_compatible endpoint (the EU presets ride this rail)' do
      let(:credential) do
        create(:ai_credential, :chat_only, provider: 'openai_compatible',
                                           api_base: 'https://api.mistral.ai/v1')
      end

      # REGRESSION: the custom-endpoint case is where a typo is most likely and
      # where the stub was most misleading.
      it 'is probed for real' do
        stub_probe(Lalabase::Llm::OpenAiCompatibleProvider, connectivity_check: false)

        expect(credential.test_connection).to be false
      end

      it 'probes the endpoint the credential actually routes to' do
        stub_probe(Lalabase::Llm::OpenAiCompatibleProvider, connectivity_check: true)

        credential.test_connection

        expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
          .with(hash_including(uri_base: 'https://api.mistral.ai/v1'))
      end
    end

    it 'returns false and logs when the probe raises' do
      credential = create(:ai_credential, :active, provider: 'openai')
      allow(Lalabase::Llm::OpenAiProvider).to receive(:new)
        .and_raise(Lalabase::Llm::Provider::AuthError, 'invalid api key')

      expect(Rails.logger).to receive(:error)
        .with(a_string_matching(/connection test failed.*invalid api key/))
      expect(credential.test_connection).to be false
    end

    it 'returns false when the credential carries no token' do
      expect(build(:ai_credential, access_token: nil).test_connection).to be false
    end
  end

  describe '#usage_stats' do
    let(:organisation) { create(:organisation) }
    let(:credential) { create(:ai_credential) }

    it 'returns total tokens used in the given time window' do
      create(:ai_usage, ai_credential: credential, organisation: organisation,
                        provider: 'openai', tokens_used: 100, used_at: 5.days.ago)
      create(:ai_usage, ai_credential: credential, organisation: organisation,
                        provider: 'openai', tokens_used: 200, used_at: 10.days.ago)

      expect(credential.usage_stats(30)).to eq(300)
    end

    it 'excludes usage outside the time window' do
      create(:ai_usage, ai_credential: credential, organisation: organisation,
                        provider: 'openai', tokens_used: 100, used_at: 5.days.ago)
      create(:ai_usage, ai_credential: credential, organisation: organisation,
                        provider: 'openai', tokens_used: 500, used_at: 60.days.ago)

      expect(credential.usage_stats(30)).to eq(100)
    end

    it 'returns 0 when no usage exists' do
      expect(credential.usage_stats).to eq(0)
    end

    it 'accepts custom day range' do
      create(:ai_usage, ai_credential: credential, organisation: organisation,
                        provider: 'openai', tokens_used: 100, used_at: 5.days.ago)
      create(:ai_usage, ai_credential: credential, organisation: organisation,
                        provider: 'openai', tokens_used: 200, used_at: 8.days.ago)

      expect(credential.usage_stats(7)).to eq(100)
    end
  end

  # ============================================================
  # Callbacks
  # ============================================================
  describe 'callbacks' do
    describe '#log_sensitive_changes' do
      it 'logs when access_token changes' do
        credential = create(:ai_credential, access_token: 'old-token')

        expect(Rails.logger).to receive(:warn).with(
          a_string_matching(/sensitive data changed/)
        )

        credential.update!(access_token: 'new-token')
      end

      it 'logs when active status changes' do
        credential = create(:ai_credential, active: false, region: 'eu')

        expect(Rails.logger).to receive(:warn).with(
          a_string_matching(/sensitive data changed/)
        )

        credential.update!(active: true)
      end

      it 'does not log when non-sensitive attributes change' do
        credential = create(:ai_credential)

        expect(Rails.logger).not_to receive(:warn)

        credential.update!(description: 'updated description')
      end
    end

    describe 'cache invalidation (S2: on EVERY write, not just active flips)' do
      it 'clears cache when active status changes' do
        credential = create(:ai_credential, active: false, region: 'eu')

        expect(Rails.cache).to receive(:delete).with("active_ai_credential_#{credential.provider}").at_least(:once)

        credential.update!(active: true)
      end

      it 'ALSO clears cache when a non-active attribute (e.g. a price) changes' do
        credential = create(:ai_credential)

        expect(Rails.cache).to receive(:delete).with("active_ai_credential_#{credential.provider}").at_least(:once)

        credential.update!(input_cost_per_1m_cents: 42)
      end
    end

    describe '#ensure_not_last_active' do
      it 'prevents destruction of the last active credential for a provider' do
        credential = create(:ai_credential, :active)

        expect(credential.destroy).to be false
        expect(credential.errors[:base]).to be_present
        expect(described_class.find(credential.id)).to be_present
      end

      it 'allows destruction when another active credential exists for the same provider' do
        credential1 = create(:ai_credential, :active, provider: 'openai')
        create(:ai_credential, provider: 'openai', active: false)

        # Deactivate credential1 first so we can destroy it
        credential1.update_column(:active, false)
        expect(credential1.destroy).to be_truthy
      end

      it 'allows destruction of inactive credentials' do
        credential = create(:ai_credential, active: false, region: 'eu')

        expect(credential.destroy).to be_truthy
        expect { described_class.find(credential.id) }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'allows destruction when active credentials exist for other providers' do
        _anthropic_active = create(:ai_credential, :active, :anthropic)
        openai_inactive = create(:ai_credential, active: false, provider: 'openai')

        expect(openai_inactive.destroy).to be_truthy
      end
    end

    # KI-Pakete P1 (§7b.2): a credential inside a published package cannot be
    # deleted — the DB says so too (FK NO ACTION), but that raises a bare
    # InvalidForeignKey. The callback turns it into a sentence NAMING the
    # packages, which is the only version an operator can act on.
    #
    # Both models get the guard for the same reason the last-active one is
    # shared: the admin backend deletes through Admin::AiCredential, so a rule
    # on the runtime class alone would never fire on the real write path.
    describe '#ensure_not_referenced_by_package' do
      it 'refuses to destroy a credential a package uses as its embedding slot, and names the package' do
        credential = create(:ai_credential, active: false, region: 'eu')
        package = create(:ai_package, embedding_credential: credential)

        expect(credential.destroy).to be(false)
        expect(credential.errors[:base]).to contain_exactly(
          I18n.t('activerecord.errors.models.ai_credential.cannot_delete_referenced_by_package',
                 packages: package.name)
        )
        expect(described_class.find_by(id: credential.id)).to be_present
      end

      it 'refuses just the same when only a chat TIER points at the credential' do
        credential = create(:ai_credential, active: false, region: 'eu')
        package = create(:ai_package)
        create(:ai_package_tier, ai_package: package, chat_credential: credential,
                                 key: 'thorough', label: AiPackageTier::DEFAULT_LABELS.fetch('thorough'))

        expect(credential.destroy).to be(false)
        expect(credential.errors.full_messages.to_sentence).to include(package.name)
        expect(described_class.find_by(id: credential.id)).to be_present
      end

      it 'lists every referencing package once, even when one package uses the credential twice' do
        credential = create(:ai_credential, active: false, region: 'eu')
        embedding_package = create(:ai_package, embedding_credential: credential)
        create(:ai_package_tier, ai_package: embedding_package, chat_credential: credential,
                                 key: 'fast', label: AiPackageTier::DEFAULT_LABELS.fetch('fast'))

        expect(credential.destroy).to be(false)
        expect(credential.errors[:base]).to contain_exactly(
          I18n.t('activerecord.errors.models.ai_credential.cannot_delete_referenced_by_package',
                 packages: embedding_package.name)
        )
      end

      it 'only protects the referenced credential, not every credential' do
        referenced = create(:ai_credential, active: false, region: 'eu')
        untouched = create(:ai_credential, active: false, region: 'eu')
        create(:ai_package, embedding_credential: referenced)

        expect(untouched.destroy).to be_truthy
        expect(described_class.find_by(id: untouched.id)).to be_nil
      end

      # Callback ORDER, pinned: a credential that is both referenced AND its
      # provider's default reports the packages. Naming "last active" first
      # would send the operator to the activate button, where nothing about the
      # package pin changes.
      it 'reports the packages, not the last-active rule, when both guards would apply' do
        credential = create(:ai_credential, :active, provider: 'openai', region: 'eu')
        package = create(:ai_package, embedding_credential: credential)

        expect(credential.destroy).to be(false)
        expect(credential.errors[:base]).to contain_exactly(
          I18n.t('activerecord.errors.models.ai_credential.cannot_delete_referenced_by_package',
                 packages: package.name)
        )
        expect(credential.errors[:base]).not_to include(
          I18n.t('activerecord.errors.models.ai_credential.cannot_delete_last_active', provider: 'openai')
        )
      end
    end
  end

  # ============================================================
  # Defaults & Schema
  # ============================================================
  describe 'database defaults' do
    it 'defaults active to false' do
      credential = described_class.new
      expect(credential.active).to be false
    end

    it 'defaults enabled to true' do
      credential = described_class.new
      expect(credential.enabled).to be true
    end

    it 'defaults provider to openai' do
      credential = described_class.new
      expect(credential.provider).to eq('openai')
    end
  end

  # ============================================================
  # Edge Cases
  # ============================================================
  describe 'edge cases' do
    it 'handles concurrent activation attempts' do
      cred1 = create(:ai_credential, provider: 'openai', active: false)
      cred2 = create(:ai_credential, provider: 'openai', active: false)

      described_class.activate!(cred1.id)
      described_class.activate!(cred2.id)

      expect(cred1.reload).not_to be_active
      expect(cred2.reload).to be_active
    end

    it 'nullifies ai_usages on destroy' do
      organisation = create(:organisation)
      credential = create(:ai_credential, active: false, region: 'eu')
      usage = create(:ai_usage, ai_credential: credential, organisation: organisation,
                                provider: 'openai', tokens_used: 100, used_at: Time.current)

      credential.destroy!

      expect(usage.reload.ai_credential_id).to be_nil
    end

    it 'handles credential with all optional fields nil' do
      credential = build(:ai_credential,
                         organization_id: nil,
                         description: nil,
                         additional_config: nil)
      expect(credential).to be_valid
    end

    it 'preserves additional_config as JSON' do
      config = { 'max_tokens' => 4096, 'temperature' => 0.7, 'nested' => { 'key' => 'value' } }
      credential = create(:ai_credential, :with_additional_config, additional_config: config)

      reloaded = described_class.find(credential.id)
      expect(reloaded.additional_config).to eq(config)
    end
  end
end

# Regression from the pre-landing review of PR #399.
RSpec.describe AiCredential, 'disable protection for referenced credentials' do
  # The destroy guard protected only `destroy`. `enabled: false` has the SAME
  # runtime effect — every package validation rejects a disabled credential —
  # so the guard was one click wide: an operator could disable a credential a
  # published package advertises, and the package was afterwards unsaveable
  # from its own form, with no way to repair the field there. Reproduced on
  # this branch before the fix.
  it 'refuses to disable a credential an AI package references, and names the package' do
    credential = create(:ai_credential, active: false, region: 'eu')
    package = create(:ai_package, :with_tiers, embedding_credential: credential, active: true)

    expect(credential.update(enabled: false)).to be(false)
    expect(credential.reload.enabled).to be(true)
    expect(credential.errors[:base].join).to include(package.name)
  end

  it 'refuses just the same when only a chat TIER points at the credential' do
    credential = create(:ai_credential, active: false, region: 'eu')
    package = create(:ai_package)
    create(:ai_package_tier, ai_package: package, chat_credential: credential,
                             key: 'thorough', label: AiPackageTier::DEFAULT_LABELS.fetch('thorough'))

    expect(credential.update(enabled: false)).to be(false)
    expect(credential.errors[:base].join).to include(package.name)
  end

  it 'leaves an unreferenced credential freely disableable' do
    credential = create(:ai_credential, active: false, region: 'eu')

    expect(credential.update(enabled: false)).to be(true)
  end

  # Re-ENABLING must never be blocked — that is the repair action.
  it 'allows re-enabling a referenced credential' do
    credential = create(:ai_credential, active: false, region: 'eu')
    create(:ai_package, embedding_credential: credential)
    credential.update_column(:enabled, false)

    expect(credential.reload.update(enabled: true)).to be(true)
  end

  # Unrelated edits must not trip the guard.
  it 'allows editing a referenced credential without touching enabled' do
    credential = create(:ai_credential, active: false, region: 'eu')
    create(:ai_package, embedding_credential: credential)

    expect(credential.update(description: 'neue Notiz')).to be(true)
  end
end

RSpec.describe AiCredential, '#residency_stated?' do
  # Residency lives in two different columns depending on provider — asking one
  # would either miss Vertex or flag it wrongly (see AiPackage's eu_native rule).
  it 'reads the region select for non-google providers' do
    expect(build(:ai_credential, provider: 'openai', region: 'eu')).to be_residency_stated
    expect(build(:ai_credential, provider: 'openai', region: nil)).not_to be_residency_stated
  end

  it "reads additional_config['location'] for google" do
    expect(build(:ai_credential, :google, region: nil)).to be_residency_stated
    expect(build(:ai_credential, :google, region: nil, additional_config: { 'project_id' => 'x' }))
      .not_to be_residency_stated
  end
end
