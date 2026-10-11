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

RSpec.describe Admin::AiCredential, type: :model do
  describe 'table configuration' do
    it 'uses the ai_credentials table' do
      expect(described_class.table_name).to eq('ai_credentials')
    end

    it 'has a custom model_name without Admin namespace' do
      expect(described_class.model_name.name).to eq('AiCredential')
      expect(described_class.model_name.singular).to eq('ai_credential')
      expect(described_class.model_name.plural).to eq('ai_credentials')
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      credential = build(:admin_ai_credential)
      expect(credential).to be_valid
    end

    # S2 (Fix A): the price guard lives on the shared AiCredentialPricing concern so
    # the ADMIN editing surface enforces it too — on the runtime model alone it would
    # be toothless (this is the class the admin backend actually writes through).
    it 'rejects a quota credential missing its prices' do
      credential = build(:admin_ai_credential, included_in_quota: true, purpose: 'chat',
                                               input_cost_per_1m_cents: nil, output_cost_per_1m_cents: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:input_cost_per_1m_cents]).to be_present
    end

    it 'accepts a non-metered credential without prices' do
      credential = build(:admin_ai_credential, included_in_quota: false,
                                               input_cost_per_1m_cents: nil, output_cost_per_1m_cents: nil)
      expect(credential).to be_valid
    end

    it 'requires name' do
      credential = build(:admin_ai_credential, name: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:name]).to be_present
    end

    it 'requires name to be non-blank' do
      credential = build(:admin_ai_credential, name: '  ')
      expect(credential).not_to be_valid
    end

    it 'requires provider' do
      credential = build(:admin_ai_credential, provider: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:provider]).to be_present
    end

    # Review of #391: both classes write the SAME table, and the runtime model has
    # required default_model all along — so every row created here without one was
    # a row the runtime path rejects. It was reachable, not theoretical: an ACTIVE
    # openai_compatible credential without a model passed the org gate and then died
    # at OpenAiCompatibleProvider#default_chat_model, which has no fallback (it
    # serves Mistral, Ollama, vLLM … — there is no honest default to fall back to).
    it 'requires default_model — the runtime model has always demanded it' do
      credential = build(:admin_ai_credential, default_model: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:default_model]).to be_present
    end

    it 'rejects a blank default_model, not just nil' do
      expect(build(:admin_ai_credential, default_model: '   ')).not_to be_valid
    end

    # S1 (honest facade): the provider rules live on the shared
    # AiCredentialProviderRules concern for the same reason as the price guard —
    # before S1 this model accepted ANY provider string (presence only), so the
    # admin backend, the actual editing surface, could create facade credentials
    # that the Factory can never build. Regression guard against re-introducing
    # that toothlessness. The full rule matrix is pinned in the AiCredential spec;
    # here we pin that the SAME rules bite on the admin write path.
    describe 'provider rules (S1, admin write path)' do
      it 'rejects unimplemented and arbitrary providers on create' do
        %w[cohere totally_made_up].each do |provider|
          credential = build(:admin_ai_credential, provider: provider)
          expect(credential).not_to be_valid, "Expected provider '#{provider}' to be invalid"
          expect(credential.errors[:provider]).to be_present
        end
      end

      it 'accepts every implemented provider' do
        Admin::AiCredential.implemented_providers.each do |provider|
          credential = build(:admin_ai_credential, provider: provider, purpose: 'chat')
          # Providers with a token-format rule need a conforming token
          credential.access_token = build(:admin_ai_credential, :google).access_token if provider == 'google'
          expect(credential).to be_valid, "Expected provider '#{provider}' to be valid"
        end
      end

      it 'rejects embedding purposes for anthropic (capability rule)' do
        credential = build(:admin_ai_credential, :anthropic, purpose: 'both')
        expect(credential).not_to be_valid
        expect(credential.errors[:purpose]).to be_present
      end

      it 'refuses to activate a legacy row with an unimplemented provider' do
        legacy = create(:admin_ai_credential)
        legacy.update_column(:provider, 'cohere')
        legacy.reload

        expect(legacy.update(active: true)).to be(false)
        expect(legacy.errors[:active]).to be_present
      end

      it 'refuses activation via .activate! (the admin controller path)' do
        legacy = create(:admin_ai_credential)
        legacy.update_column(:provider, 'cohere')

        expect { described_class.activate!(legacy.id) }
          .to raise_error(ActiveRecord::RecordInvalid)
        expect(legacy.reload.active).to be(false)
      end

      # The factory default is active: false, which is load-bearing here: an
      # ACTIVE row would be held back by AiCredentialDestroyProtection, and this
      # example would then test that guard instead of the provider rules.
      it 'keeps legacy rows editable and destroyable' do
        legacy = create(:admin_ai_credential)
        legacy.update_column(:provider, 'cohere')
        legacy.reload

        expect(legacy.update(description: 'still editable')).to be(true)
        expect(legacy.destroy).to be_truthy
      end
    end

    # E12 (P2): the company-domicile rule must bite HERE — the admin backend is
    # where the field is edited. A runtime-only validation would be toothless,
    # the exact gap the P0 destroy guard closed for callbacks.
    describe 'company domicile rule (admin write path)' do
      it 'rejects a value outside the domicile list' do
        credential = build(:admin_ai_credential, company_domicile: 'mars')
        expect(credential).not_to be_valid
        expect(credential.errors[:company_domicile]).to be_present
      end

      it 'accepts blank as "not recorded" — the form select carries an empty option' do
        expect(build(:admin_ai_credential, company_domicile: '')).to be_valid
        expect(build(:admin_ai_credential, company_domicile: 'eu')).to be_valid
      end
    end

    # GoogleVertexProvider slice: the SA-JSON rule must bite HERE — the admin
    # backend is where google credentials are actually written. Full matrix in
    # the AiCredential spec; this is the admin-write-path twin.
    describe 'google service-account JSON rule (admin write path)' do
      it 'accepts the SA-JSON factory trait' do
        expect(build(:admin_ai_credential, :google)).to be_valid
      end

      it 'rejects an API key where the SA JSON belongs' do
        credential = build(:admin_ai_credential, :google, access_token: 'AIzaSyLegacyKey123')
        expect(credential).not_to be_valid
        expect(credential.errors[:access_token]).to be_present
      end

      it 'rejects an SA JSON missing private_key' do
        json = { type: 'service_account', client_email: 'x@y.iam.gserviceaccount.com' }.to_json
        credential = build(:admin_ai_credential, :google, access_token: json)
        expect(credential).not_to be_valid
        expect(credential.errors[:access_token]).to be_present
      end
    end

    it 'requires access_token' do
      credential = build(:admin_ai_credential, access_token: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:access_token]).to be_present
    end
  end

  describe 'associations' do
    it 'has many ai_usages with nullify dependent' do
      assoc = described_class.reflect_on_association(:ai_usages)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:dependent]).to eq(:nullify)
      expect(assoc.options[:class_name]).to eq('Admin::AiUsage')
    end
  end

  describe 'scopes' do
    let!(:active_openai) { create(:admin_ai_credential, :active, provider: 'openai', name: 'OpenAI Active') }
    let!(:inactive_openai) { create(:admin_ai_credential, provider: 'openai', name: 'OpenAI Inactive') }
    let!(:active_anthropic) { create(:admin_ai_credential, :active, :anthropic, name: 'Anthropic Active') }
    let!(:disabled_credential) { create(:admin_ai_credential, :disabled, :anthropic, name: 'Disabled One') }

    describe '.active' do
      it 'returns only active credentials' do
        expect(described_class.active).to contain_exactly(active_openai, active_anthropic)
      end
    end

    describe '.inactive' do
      it 'returns only inactive credentials' do
        expect(described_class.inactive).to contain_exactly(inactive_openai, disabled_credential)
      end
    end

    describe '.enabled' do
      it 'returns only enabled credentials' do
        expect(described_class.enabled).to contain_exactly(active_openai, inactive_openai, active_anthropic)
      end
    end

    describe '.disabled' do
      it 'returns only disabled credentials' do
        expect(described_class.disabled).to contain_exactly(disabled_credential)
      end
    end

    describe '.by_provider' do
      it 'filters by provider' do
        expect(described_class.by_provider('openai')).to contain_exactly(active_openai, inactive_openai)
        expect(described_class.by_provider('anthropic')).to contain_exactly(active_anthropic, disabled_credential)
      end

      it 'returns empty for non-existent provider' do
        expect(described_class.by_provider('cohere')).to be_empty
      end
    end

    describe '.ordered_by_name' do
      it 'orders alphabetically by name' do
        result = described_class.ordered_by_name
        expect(result.first.name).to be <= result.last.name
      end
    end

    describe '.ordered_by_provider' do
      it 'orders by provider, then name' do
        result = described_class.ordered_by_provider
        providers = result.pluck(:provider)
        expect(providers).to eq(providers.sort)
      end
    end
  end

  describe '.providers' do
    it 'returns distinct sorted providers from the database' do
      create(:admin_ai_credential, provider: 'openai')
      create(:admin_ai_credential, :anthropic)
      create(:admin_ai_credential, provider: 'openai')

      expect(described_class.providers).to eq(%w[anthropic openai])
    end

    it 'returns empty array when no credentials exist' do
      expect(described_class.providers).to eq([])
    end
  end

  describe '.activate!' do
    let!(:cred_a) { create(:admin_ai_credential, :active, provider: 'openai', name: 'A') }
    let!(:cred_b) { create(:admin_ai_credential, provider: 'openai', name: 'B') }
    let!(:cred_other) { create(:admin_ai_credential, :active, :anthropic, name: 'Other') }

    it 'activates the given credential' do
      described_class.activate!(cred_b.id)
      expect(cred_b.reload.active).to be true
    end

    it 'deactivates other credentials of the same provider' do
      described_class.activate!(cred_b.id)
      expect(cred_a.reload.active).to be false
    end

    it 'does not affect credentials of other providers' do
      described_class.activate!(cred_b.id)
      expect(cred_other.reload.active).to be true
    end

    it 'raises RecordNotFound for invalid id' do
      expect do
        described_class.activate!('00000000-0000-0000-0000-000000000000')
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'is atomic — no partial updates on failure' do
      allow_any_instance_of(described_class).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      expect do
        described_class.activate!(cred_b.id)
      rescue StandardError
        nil
      end.not_to(change { cred_a.reload.active })
    end
  end

  # KI-Pakete P0: the last-active guard now lives in AiCredentialDestroyProtection
  # and is included HERE too. Before that it was registered on the runtime model
  # only — and no destroy in the app ever goes through that class, so the guard
  # protected nothing: the admin backend deleted a provider's only active
  # credential without a word. These examples pin the guard on the class that
  # actually gets destroyed.
  describe 'destroy protection (last active credential of a provider)' do
    it 'refuses to destroy the last active credential and explains why' do
      credential = create(:admin_ai_credential, :active, provider: 'openai')

      expect(credential.destroy).to be(false)
      # The message resolves only because model_name is overridden to
      # 'AiCredential' — the i18n key is shared with the runtime model.
      expect(credential.errors[:base]).to contain_exactly(
        I18n.t('activerecord.errors.models.ai_credential.cannot_delete_last_active', provider: 'openai')
      )
      expect(described_class.find_by(id: credential.id)).to be_present
    end

    it 'allows destroying an inactive credential' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')

      expect(credential.destroy).to be_truthy
      expect(described_class.find_by(id: credential.id)).to be_nil
    end

    it 'only protects the own provider, not any active credential' do
      create(:admin_ai_credential, :active, :anthropic)
      openai_inactive = create(:admin_ai_credential, active: false, provider: 'openai')

      expect(openai_inactive.destroy).to be_truthy
    end
  end

  # KI-Pakete P1 (§7b.2): the package guard, on the class the admin backend
  # really destroys. AiPackage points at AiCredential, and both classes map to
  # the same table — so a package built on the runtime class references these
  # rows just as well; the reference is a row id, not a class.
  describe 'destroy protection (referenced by an AI package)' do
    it 'refuses to destroy a credential a package uses as its embedding slot, and names the package' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      package = create(:ai_package, embedding_credential_id: credential.id)

      expect(credential.destroy).to be(false)
      # Resolves only because model_name is overridden to 'AiCredential' — the
      # i18n key is shared with the runtime model, same as cannot_delete_last_active.
      expect(credential.errors[:base]).to contain_exactly(
        I18n.t('activerecord.errors.models.ai_credential.cannot_delete_referenced_by_package',
               packages: package.name)
      )
      expect(described_class.find_by(id: credential.id)).to be_present
    end

    it 'refuses just the same when only a chat TIER points at the credential' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      package = create(:ai_package)
      create(:ai_package_tier, ai_package: package, chat_credential_id: credential.id,
                               key: 'thorough', label: AiPackageTier::DEFAULT_LABELS.fetch('thorough'))

      expect(credential.destroy).to be(false)
      expect(credential.errors.full_messages.to_sentence).to include(package.name)
      expect(described_class.find_by(id: credential.id)).to be_present
    end

    it 'leaves unreferenced credentials destroyable' do
      referenced = create(:admin_ai_credential, active: false, region: 'eu')
      untouched = create(:admin_ai_credential, active: false, region: 'eu')
      create(:ai_package, embedding_credential_id: referenced.id)

      expect(untouched.destroy).to be_truthy
      expect(described_class.find_by(id: untouched.id)).to be_nil
    end

    # Callback order, pinned on the admin path too — see the runtime spec.
    it 'reports the packages, not the last-active rule, when both guards would apply' do
      credential = create(:admin_ai_credential, :active, provider: 'openai', region: 'eu')
      package = create(:ai_package, embedding_credential_id: credential.id)

      expect(credential.destroy).to be(false)
      expect(credential.errors[:base]).to contain_exactly(
        I18n.t('activerecord.errors.models.ai_credential.cannot_delete_referenced_by_package',
               packages: package.name)
      )
    end
  end

  describe '#status_text' do
    it 'returns active_enabled when active and enabled' do
      credential = build(:admin_ai_credential, :active, enabled: true)
      expect(credential.status_text).to eq(I18n.t('models.admin_ai_credential.status.active_enabled'))
    end

    it 'returns active_disabled when active but disabled' do
      credential = build(:admin_ai_credential, :active_disabled)
      expect(credential.status_text).to eq(I18n.t('models.admin_ai_credential.status.active_disabled'))
    end

    it 'returns inactive when not active' do
      credential = build(:admin_ai_credential, active: false)
      expect(credential.status_text).to eq(I18n.t('models.admin_ai_credential.status.inactive'))
    end

    it 'returns inactive when not active even if enabled' do
      credential = build(:admin_ai_credential, active: false, enabled: true)
      expect(credential.status_text).to eq(I18n.t('models.admin_ai_credential.status.inactive'))
    end
  end

  describe '#organization_display' do
    it 'returns organization_id when present' do
      credential = build(:admin_ai_credential, :with_organization)
      expect(credential.organization_display).to eq('org-12345')
    end

    it 'returns i18n fallback when nil' do
      credential = build(:admin_ai_credential, organization_id: nil)
      expect(credential.organization_display).to eq(I18n.t('models.admin_ai_credential.display.no_organization_id'))
    end

    it 'returns i18n fallback when empty string' do
      credential = build(:admin_ai_credential, organization_id: '')
      expect(credential.organization_display).to eq(I18n.t('models.admin_ai_credential.display.no_organization_id'))
    end
  end

  describe '#model_display' do
    it 'returns default_model when present' do
      credential = build(:admin_ai_credential, default_model: 'gpt-4')
      expect(credential.model_display).to eq('gpt-4')
    end

    it 'returns i18n fallback when nil' do
      credential = build(:admin_ai_credential, default_model: nil)
      expect(credential.model_display).to eq(I18n.t('models.admin_ai_credential.display.no_default_model'))
    end

    it 'returns i18n fallback when empty string' do
      credential = build(:admin_ai_credential, default_model: '')
      expect(credential.model_display).to eq(I18n.t('models.admin_ai_credential.display.no_default_model'))
    end
  end

  describe '#has_access_token?' do
    it 'returns true when token present' do
      credential = build(:admin_ai_credential)
      expect(credential.has_access_token?).to be true
    end

    it 'returns false when token nil' do
      credential = build(:admin_ai_credential)
      credential.access_token = nil
      expect(credential.has_access_token?).to be false
    end

    it 'returns false when token blank' do
      credential = build(:admin_ai_credential)
      credential.access_token = ''
      expect(credential.has_access_token?).to be false
    end
  end

  describe '#masked_access_token' do
    it 'is a fixed five-asterisk mask regardless of token length (no wall, no length leak)' do
      # A per-char mask turned a service-account JSON into a card-breaking wall.
      short = build(:admin_ai_credential, access_token: 'abc')
      long  = build(:admin_ai_credential, access_token: 'x' * 3000)
      expect(short.masked_access_token).to eq('*****')
      expect(long.masked_access_token).to eq('*****')
    end

    it "keeps a '*' (update write-back guard) and never reveals the real value" do
      credential = build(:admin_ai_credential, access_token: 'sk-super-secret-value')
      masked = credential.masked_access_token
      expect(masked).to include('*')
      expect(masked).not_to include('secret')
    end

    it 'returns i18n no_token when token is nil' do
      credential = build(:admin_ai_credential)
      credential.access_token = nil
      expect(credential.masked_access_token).to eq(I18n.t('models.admin_ai_credential.display.no_token'))
    end

    it 'returns i18n no_token when token is blank' do
      credential = build(:admin_ai_credential)
      credential.access_token = ''
      expect(credential.masked_access_token).to eq(I18n.t('models.admin_ai_credential.display.no_token'))
    end

    it 'is aliased as masked_token' do
      credential = build(:admin_ai_credential)
      expect(credential.masked_token).to eq(credential.masked_access_token)
    end
  end

  # key_fingerprint is the list-view identifier: type prefix + last 4 chars, with
  # NO length leak and no scroll-breaking wall of asterisks (the list bug we fixed).
  describe '#key_fingerprint' do
    it 'shows the type prefix and last four characters' do
      credential = build(:admin_ai_credential, access_token: 'sk-proj-abcdefghijklmnop3hLx')
      expect(credential.key_fingerprint).to eq('sk-…3hLx')
    end

    it 'does not leak the token length (short, fixed shape regardless of key size)' do
      short = build(:admin_ai_credential, access_token: "sk-#{'a' * 20}wxyz")
      long  = build(:admin_ai_credential, access_token: "sk-#{'a' * 200}wxyz")
      expect(short.key_fingerprint).to eq(long.key_fingerprint)
      expect(short.key_fingerprint.length).to be < 10
    end

    it 'never emits a run of asterisks' do
      credential = build(:admin_ai_credential, access_token: 'sk-test-token-1234567890abcdef')
      expect(credential.key_fingerprint).not_to include('*')
    end

    it 'only reveals the last four characters for very short tokens' do
      credential = build(:admin_ai_credential, access_token: 'abcdef')
      expect(credential.key_fingerprint).to eq('…cdef')
    end

    it 'returns the i18n no_token fallback when the token is blank' do
      credential = build(:admin_ai_credential)
      credential.access_token = ''
      expect(credential.key_fingerprint).to eq(I18n.t('models.admin_ai_credential.display.no_token'))
    end
  end

  describe 'usage statistics' do
    let(:organisation) { create(:organisation) }
    let(:credential) { create(:admin_ai_credential) }

    let!(:recent_usage) do
      create(:admin_ai_usage,
             ai_credential: credential,
             organisation: organisation,
             tokens_used: 500,
             cost_cents: 10,
             used_at: 5.days.ago)
    end

    let!(:old_usage) do
      create(:admin_ai_usage,
             ai_credential: credential,
             organisation: organisation,
             tokens_used: 1000,
             cost_cents: 20,
             used_at: 60.days.ago)
    end

    describe '#total_usage_tokens' do
      it 'sums all tokens across all usages' do
        expect(credential.total_usage_tokens).to eq(1500)
      end

      it 'returns 0 when no usages exist' do
        empty_cred = create(:admin_ai_credential)
        expect(empty_cred.total_usage_tokens).to eq(0)
      end
    end

    describe '#total_usage_cost_cents' do
      it 'sums all cost_cents across all usages' do
        expect(credential.total_usage_cost_cents).to eq(30)
      end
    end

    describe '#recent_usage_tokens' do
      it 'sums tokens only within the given period (default 30 days)' do
        expect(credential.recent_usage_tokens).to eq(500)
      end

      it 'respects custom days parameter' do
        expect(credential.recent_usage_tokens(90)).to eq(1500)
      end

      it 'returns 0 for very short period with no data' do
        expect(credential.recent_usage_tokens(1)).to eq(0)
      end
    end

    describe '#recent_usage_cost_cents' do
      it 'sums cost_cents only within the given period' do
        expect(credential.recent_usage_cost_cents).to eq(10)
      end

      it 'respects custom days parameter' do
        expect(credential.recent_usage_cost_cents(90)).to eq(30)
      end
    end

    describe '#usage_count' do
      it 'returns total number of usages' do
        expect(credential.usage_count).to eq(2)
      end
    end

    describe '#recent_usage_count' do
      it 'returns count within the given period' do
        expect(credential.recent_usage_count).to eq(1)
        expect(credential.recent_usage_count(90)).to eq(2)
      end
    end
  end

  describe '#status_css_class' do
    it 'returns green for active and enabled' do
      credential = build(:admin_ai_credential, :active, enabled: true)
      expect(credential.status_css_class).to eq('bg-green-100 text-green-800')
    end

    it 'returns yellow for active but disabled' do
      credential = build(:admin_ai_credential, :active_disabled)
      expect(credential.status_css_class).to eq('bg-yellow-100 text-yellow-800')
    end

    it 'returns red for inactive regardless of enabled' do
      credential = build(:admin_ai_credential, active: false, enabled: true)
      expect(credential.status_css_class).to eq('bg-red-100 text-red-800')
    end

    it 'returns red for inactive and disabled' do
      credential = build(:admin_ai_credential, active: false, enabled: false)
      expect(credential.status_css_class).to eq('bg-red-100 text-red-800')
    end
  end

  describe '#provider_css_class' do
    it 'returns green for openai' do
      expect(build(:admin_ai_credential, provider: 'openai').provider_css_class)
        .to eq('bg-green-100 text-green-800')
    end

    it 'returns blue for anthropic' do
      expect(build(:admin_ai_credential, provider: 'anthropic').provider_css_class)
        .to eq('bg-blue-100 text-blue-800')
    end

    it 'returns blue for claude' do
      expect(build(:admin_ai_credential, provider: 'claude').provider_css_class)
        .to eq('bg-blue-100 text-blue-800')
    end

    it 'returns yellow for google' do
      expect(build(:admin_ai_credential, provider: 'google').provider_css_class)
        .to eq('bg-yellow-100 text-yellow-800')
    end

    it 'returns gray default for unknown provider' do
      expect(build(:admin_ai_credential, provider: 'cohere').provider_css_class)
        .to eq('bg-gray-100 text-gray-800')
    end

    it 'handles mixed-case provider names' do
      expect(build(:admin_ai_credential, provider: 'OpenAI').provider_css_class)
        .to eq('bg-green-100 text-green-800')
    end

    it 'returns default when provider is nil' do
      credential = build(:admin_ai_credential)
      credential.provider = nil
      expect(credential.provider_css_class).to eq('bg-gray-100 text-gray-800')
    end
  end

  describe '#additional_config_display' do
    it 'returns i18n fallback when config is nil' do
      credential = build(:admin_ai_credential, additional_config: nil)
      expect(credential.additional_config_display)
        .to eq(I18n.t('models.admin_ai_credential.display.no_extra_config'))
    end

    it 'returns i18n fallback when config is empty hash' do
      credential = build(:admin_ai_credential, additional_config: {})
      expect(credential.additional_config_display)
        .to eq(I18n.t('models.admin_ai_credential.display.no_extra_config'))
    end

    it 'formats config entries as humanized key-value pairs' do
      credential = build(:admin_ai_credential, :with_additional_config)
      result = credential.additional_config_display
      expect(result).to include('Max tokens: 4096')
      expect(result).to include('Temperature: 0.7')
    end

    it 'joins multiple entries with comma' do
      credential = build(:admin_ai_credential, additional_config: { 'a' => 1, 'b' => 2 })
      expect(credential.additional_config_display).to eq('A: 1, B: 2')
    end
  end

  # S1: delegates to AiCredential.provider_display_names — the ONE display-name
  # source. The old admin-local map (with its phantom 'claude' key) is gone.
  describe '#provider_display_name' do
    it 'returns the shared display name for every known provider' do
      ::AiCredential.provider_display_names.each do |provider, display_name|
        expect(build(:admin_ai_credential, provider: provider).provider_display_name).to eq(display_name)
      end
    end

    it 'capitalizes unknown providers (incl. the phantom claude and removed cohere)' do
      expect(build(:admin_ai_credential, provider: 'claude').provider_display_name).to eq('Claude')
      expect(build(:admin_ai_credential, provider: 'cohere').provider_display_name).to eq('Cohere')
    end

    it 'returns nil when provider is nil' do
      credential = build(:admin_ai_credential)
      credential.provider = nil
      expect(credential.provider_display_name).to be_nil
    end
  end

  describe '#usage_stats' do
    let(:organisation) { create(:organisation) }
    let(:credential) { create(:admin_ai_credential) }

    context 'with usage data' do
      before do
        create(:admin_ai_usage, ai_credential: credential, organisation: organisation,
                                tokens_used: 600, cost_cents: 12, used_at: 3.days.ago)
        create(:admin_ai_usage, ai_credential: credential, organisation: organisation,
                                tokens_used: 400, cost_cents: 8, used_at: 10.days.ago)
      end

      it 'returns correct stats hash' do
        stats = credential.usage_stats
        expect(stats[:total_requests]).to eq(2)
        expect(stats[:total_tokens]).to eq(1000)
        expect(stats[:total_cost_cents]).to eq(20)
        expect(stats[:average_tokens_per_request]).to eq(500)
      end

      it 'respects custom days parameter' do
        create(:admin_ai_usage, ai_credential: credential, organisation: organisation,
                                tokens_used: 200, cost_cents: 4, used_at: 60.days.ago)

        stats = credential.usage_stats(90)
        expect(stats[:total_requests]).to eq(3)
        expect(stats[:total_tokens]).to eq(1200)
      end
    end

    context 'without usage data' do
      it 'returns zeros' do
        stats = credential.usage_stats
        expect(stats[:total_requests]).to eq(0)
        expect(stats[:total_tokens]).to eq(0)
        expect(stats[:total_cost_cents]).to eq(0)
        expect(stats[:average_tokens_per_request]).to eq(0)
      end
    end
  end

  # #test_connection is covered in ONE place further down — it used to be split
  # across two describe blocks pinning two different halves of the old
  # per-provider behaviour.

  describe '#credential_summary' do
    let(:organisation) { create(:organisation) }
    let(:credential) { create(:admin_ai_credential, :with_organization, name: 'Test Cred', provider: 'openai', default_model: 'gpt-4') }

    before do
      create(:admin_ai_usage, ai_credential: credential, organisation: organisation,
                              tokens_used: 100, cost_cents: 2, used_at: 5.days.ago)
    end

    it 'returns a complete summary hash' do
      summary = credential.credential_summary

      expect(summary[:name]).to eq('Test Cred')
      expect(summary[:provider]).to eq('OpenAI (GPT)')
      expect(summary[:status]).to be_a(String)
      expect(summary[:organization_id]).to eq('org-12345')
      expect(summary[:default_model]).to eq('gpt-4')
      expect(summary[:total_usage_tokens]).to eq(100)
      expect(summary[:total_usage_cost_cents]).to eq(2)
      expect(summary[:recent_usage_tokens]).to eq(100)
      expect(summary[:recent_usage_cost_cents]).to eq(2)
      expect(summary[:usage_count]).to eq(1)
      expect(summary[:has_access_token]).to be true
    end

    it 'handles credential without usages' do
      empty_cred = create(:admin_ai_credential)
      summary = empty_cred.credential_summary

      expect(summary[:total_usage_tokens]).to eq(0)
      expect(summary[:usage_count]).to eq(0)
    end
  end

  # The admin backend is the REAL create/edit surface for AI credentials, so the
  # access_token (service-account JSON / API keys) must be encrypted at rest here —
  # not only on the runtime model. These specs pin BOTH halves of the contract:
  # new writes are ciphertext at rest, and the one-time backfill converts existing
  # cleartext rows without breaking the transparent-read roundtrip.
  describe 'access_token encryption at rest' do
    # Reads the value straight from the column, bypassing the decrypting attribute
    # type, so the assertion sees what is ACTUALLY persisted (cleartext vs. envelope).
    def raw_access_token(id)
      conn = described_class.connection
      conn.select_value("SELECT access_token FROM ai_credentials WHERE id = #{conn.quote(id)}")
    end

    # Forces a legacy CLEARTEXT row (the pre-fix state) past the encrypting setter.
    def store_cleartext(credential, value)
      conn = described_class.connection
      conn.execute("UPDATE ai_credentials SET access_token = #{conn.quote(value)} WHERE id = #{conn.quote(credential.id)}")
    end

    it 'persists the access_token as ciphertext, never cleartext' do
      secret = 'sk-super-secret-value-123'
      credential = create(:admin_ai_credential, access_token: secret)

      stored = raw_access_token(credential.id)
      expect(stored).not_to include(secret)
      expect(stored).to include('"p"') # ActiveRecord::Encryption envelope marker
    end

    it 'decrypts transparently on read' do
      secret = 'sk-super-secret-value-123'
      credential = create(:admin_ai_credential, access_token: secret)
      expect(described_class.find(credential.id).access_token).to eq(secret)
    end

    it 'rejects legacy cleartext rows instead of silently accepting them (support_unencrypted_data is off)' do
      # Inverse of the retired bridge spec that stood here: until the one-time
      # production backfill (encryption:reencrypt_tokens) ran, the
      # support_unencrypted_data bridge kept cleartext rows readable. Since the
      # cutoff, a cleartext value in this column is a DEFECT (a write path
      # bypassing `encrypts`) — reading it must raise, never quietly hand the
      # value back as if the column were healthy.
      credential = create(:admin_ai_credential)
      store_cleartext(credential, 'legacy-cleartext-token')

      expect { described_class.find(credential.id).access_token }
        .to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    end

    describe '.reencrypt_access_tokens!' do
      it 'skips a legacy cleartext row untouched (the backfill window is over)' do
        # Pre-cutoff this example proved the cleartext BACKFILL; that window
        # closed with support_unencrypted_data = false. A cleartext row now
        # raises on read, so the sweep surfaces it as failed and leaves it
        # byte-identical — repairing it is a manual decision, not something a
        # maintenance task silently invents an interpretation for.
        credential = create(:admin_ai_credential)
        store_cleartext(credential, 'legacy-plaintext-token')
        expect(raw_access_token(credential.id)).to eq('legacy-plaintext-token') # cleartext at rest

        result = described_class.reencrypt_access_tokens!

        expect(result).to eq(processed: 0, failed: 1)
        expect(raw_access_token(credential.id)).to eq('legacy-plaintext-token') # untouched
      end

      it 'leaves already-encrypted rows readable (idempotent)' do
        credential = create(:admin_ai_credential, access_token: 'already-encrypted-token')
        described_class.reencrypt_access_tokens!
        expect(described_class.find(credential.id).access_token).to eq('already-encrypted-token')
      end

      it 'does not bump updated_at (repair, not a domain change)' do
        credential = create(:admin_ai_credential)
        before = credential.reload.updated_at

        described_class.reencrypt_access_tokens!

        expect(credential.reload.updated_at).to eq(before)
      end

      it 'isolates a row that raises while processing and still encrypts the rest (per-row rescue)' do
        # An injected raising row pins the isolation contract itself: one row
        # throwing (for ANY reason — decryption under a retired key, a DB
        # error) must never abort the batch and leave later rows under the old
        # key.
        good = create(:admin_ai_credential, access_token: 'good-token-value')
        bad = instance_double(described_class, id: SecureRandom.uuid)
        allow(bad).to receive(:access_token).and_raise(ActiveRecord::Encryption::Errors::Decryption)
        allow(bad).to receive(:update_columns) # never reached with its only column broken, stubbed defensively
        allow(described_class).to receive(:find_each).and_yield(good).and_yield(bad)

        # Only the good row counts as processed; the broken one surfaces in failed.
        expect(described_class.reencrypt_access_tokens!).to eq(processed: 1, failed: 1)
        expect(described_class.find(good.id).access_token).to eq('good-token-value')
      end
    end
  end

  describe 'constants' do
    it 'no longer carries its own display-name map (S1: one source on AiCredential)' do
      expect(Admin::AiCredential.const_defined?(:PROVIDER_DISPLAY_NAMES, false)).to be(false)
    end

    it 'has frozen PROVIDER_CSS_CLASSES' do
      expect(Admin::AiCredential::PROVIDER_CSS_CLASSES).to be_frozen
    end

    it 'PROVIDER_CSS_CLASSES has a class for every implemented provider or a default fallback' do
      Admin::AiCredential.implemented_providers.each do |provider|
        css = build(:admin_ai_credential, provider: provider).provider_css_class
        expect(css).to be_present
      end
    end
  end

  # Both models now share ONE probe (AiCredentialConnectivity): every
  # implemented provider goes through Provider#connectivity_check. google keeps
  # the behaviour it had here before — GoogleVertexProvider#connectivity_check
  # mints the same OAuth token and thereby validates the whole SA JSON — while
  # every other provider lost its `access_token.present?` stub, which reported
  # success for credentials that could not connect at all.
  #
  # The admin model's one specialty stays pinned: the secret must be read
  # through the RUNTIME model, because only AiCredential declares `encrypts`
  # (this model would hand back ciphertext for an encrypted row).
  describe '#test_connection' do
    def stub_probe(klass, **kwargs)
      instance_double(klass, **kwargs).tap do |probe|
        allow(klass).to receive(:new).and_return(probe)
      end
    end

    context 'with a google credential' do
      let(:credential) { create(:admin_ai_credential, :google) }

      it 'is true when the probe round-trips, on the SA JSON read through the runtime model' do
        stub_probe(Lalabase::Llm::GoogleVertexProvider, connectivity_check: true)

        expect(credential.test_connection).to be(true)
        expect(Lalabase::Llm::GoogleVertexProvider).to have_received(:new)
          .with(hash_including(api_key: AiCredential.find(credential.id).access_token))
      end

      it 'is false when the probe does not round-trip' do
        stub_probe(Lalabase::Llm::GoogleVertexProvider, connectivity_check: false)

        expect(credential.test_connection).to be(false)
      end

      it 'is false when the probe raises AuthError (broken SA JSON / revoked key)' do
        probe = instance_double(Lalabase::Llm::GoogleVertexProvider)
        allow(probe).to receive(:connectivity_check)
          .and_raise(Lalabase::Llm::Provider::AuthError, 'google token mint failed: invalid_grant')
        allow(Lalabase::Llm::GoogleVertexProvider).to receive(:new).and_return(probe)

        expect(credential.test_connection).to be(false)
      end
    end

    context 'with a non-google credential' do
      # REGRESSION: returned true for any non-empty token before the concern.
      it 'is probed for real instead of trusting token presence' do
        credential = create(:admin_ai_credential) # openai
        stub_probe(Lalabase::Llm::OpenAiProvider, connectivity_check: false)

        expect(credential.test_connection).to be(false)
      end
    end

    it 'is false when disabled, without building a provider' do
      credential = create(:admin_ai_credential, :disabled)
      allow(Lalabase::Llm::OpenAiProvider).to receive(:new)

      expect(credential.test_connection).to be(false)
      expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
    end

    # No "missing token" example here: this model validates access_token
    # presence, so the state is unreachable through it. The runtime model spec
    # covers it (an unvalidated `build` can carry a nil token).
  end
end
