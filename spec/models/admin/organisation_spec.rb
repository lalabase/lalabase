# frozen_string_literal: true

# == Schema Information
#
# Table name: organisations
#
#  id                        :uuid             not null, primary key
#  ai_access_token           :text
#  ai_activated_at           :datetime
#  ai_api_base               :string
#  ai_connection_checked_at  :datetime
#  ai_connection_status      :string
#  ai_enabled                :boolean          default(FALSE), not null
#  ai_package_selected_at    :datetime
#  ai_package_tier_key       :string
#  ai_provider               :string           default("openai")
#  ai_quota_buffer_override  :integer
#  ai_quota_credits_override :integer
#  data_import_enabled       :boolean          default(FALSE), not null
#  domain                    :string
#  email_subject_prefix      :string
#  embedding_access_token    :text
#  embedding_api_base        :string
#  embedding_dims            :integer
#  embedding_model           :string
#  embedding_provider        :string
#  embedding_retention_limit :integer          default(2), not null
#  name                      :string
#  notification_sender_email :string
#  preferred_chat_model      :string
#  project_chat_enabled      :boolean          default(FALSE), not null
#  subdomain                 :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :uuid
#  active_embedding_space_id :uuid
#  ai_activated_by_id        :uuid
#  ai_organization_id        :string
#  ai_package_id             :uuid
#  ai_package_selected_by_id :uuid
#  embedding_organization_id :string
#
# Indexes
#
#  index_organisations_on_account_id                 (account_id)
#  index_organisations_on_ai_activated_by_id         (ai_activated_by_id)
#  index_organisations_on_ai_package_id              (ai_package_id)
#  index_organisations_on_ai_provider                (ai_provider)
#  index_organisations_on_notification_sender_email  (notification_sender_email)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (active_embedding_space_id => embedding_spaces.id) ON DELETE => nullify
#  fk_rails_...  (ai_activated_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (ai_package_id => ai_packages.id)
#  fk_rails_...  (ai_package_selected_by_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

RSpec.describe Admin::Organisation, type: :model do
  # ---------------------------------------------------------------------------
  # Setup: Admin::Organisation uses the same table but WITHOUT acts_as_tenant.
  # We create records directly via Admin models to avoid tenant scoping.
  # ---------------------------------------------------------------------------

  let(:organisation) { described_class.create!(name: 'Test Org', domain: 'test.local', subdomain: 'test') }

  # =========================================================================
  # Table & routing configuration
  # =========================================================================

  describe 'table configuration' do
    it 'uses the organisations table' do
      expect(described_class.table_name).to eq('organisations')
    end

    it 'shares the table with the regular Organisation model' do
      expect(described_class.table_name).to eq(Organisation.table_name)
    end
  end

  describe '.model_name' do
    it 'returns Organisation without Admin prefix for routing' do
      expect(described_class.model_name.name).to eq('Organisation')
      expect(described_class.model_name.singular).to eq('organisation')
      expect(described_class.model_name.plural).to eq('organisations')
    end
  end

  # =========================================================================
  # Validations
  # =========================================================================

  describe 'validations' do
    it 'requires name to be present' do
      org = described_class.new(name: nil)
      expect(org).not_to be_valid
      expect(org.errors[:name]).to be_present
    end

    it 'requires name to be unique' do
      described_class.create!(name: 'Unique Org')
      duplicate = described_class.new(name: 'Unique Org')
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it 'allows blank domain and subdomain' do
      org = described_class.new(name: 'No Domain Org')
      expect(org).to be_valid
    end

    # Mirror of the regular Organisation model's embedding_dims gate (v2 §3.2) —
    # same table, so an admin-side write bypassing that model must hit the SAME
    # allowlist, or the Factory trusts a dim no storage lane accepts.
    describe 'embedding_dims (mirrored from Organisation)' do
      it 'allows nil and every SUPPORTED_DIMS value (sharp since PR 5)' do
        expect(described_class.new(name: 'Dims Org A', embedding_dims: nil)).to be_valid
        ::Organisation::SUPPORTED_DIMS.each_with_index do |dims, index|
          expect(described_class.new(name: "Dims Org B#{index}", embedding_dims: dims)).to be_valid
        end
      end

      # The mirror must reject exactly what the org model rejects. 3072 was listed here while
      # it had no storage lane; PR 5b shipped that lane, so it is now covered by the positive
      # case above (which iterates Organisation::SUPPORTED_DIMS and therefore follows along on
      # its own). 999 stays as the typo guard.
      [999].each do |dims|
        it "rejects #{dims} (outside Organisation::SUPPORTED_DIMS)" do
          org = described_class.new(name: "Dims Org C#{dims}", embedding_dims: dims)
          expect(org).not_to be_valid
          expect(org.errors[:embedding_dims]).to be_present
        end
      end
    end
  end

  # =========================================================================
  # Associations
  # =========================================================================

  describe 'associations' do
    it { is_expected.to have_many(:memberships).class_name('Admin::Membership').dependent(:destroy) }
    it { is_expected.to have_many(:users).through(:memberships).class_name('Admin::User') }
    it { is_expected.to have_many(:projects).class_name('Admin::Project').dependent(:destroy) }
    it { is_expected.to have_many(:roles).class_name('Admin::Role').dependent(:destroy) }
    it { is_expected.to have_many(:ai_usages).class_name('Admin::AiUsage').dependent(:destroy) }
    it { is_expected.to belong_to(:account).optional }
  end

  # =========================================================================
  # #ensure_account (Plan doc/billing_agentur_konto_plan.md D8) -- this path
  # bypasses the regular Organisation model entirely (Actors::CreateUserWithOrganisation
  # uses Admin::Organisation), so it needs its own mirrored callback.
  # =========================================================================

  describe '#ensure_account' do
    after { Current.user = nil }

    it 'auto-creates a 1:1, owner-less Account when Current.user is nil (the normal admin path)' do
      org = described_class.create!(name: 'Admin-Created Org')

      expect(org.account).to be_present
      expect(org.account.owner).to be_nil
    end

    # Proves the mirrored callback (AccountAutoAssignable) really reads
    # Current.user the same way the regular Organisation model does -- not
    # just that it happens to produce owner: nil in the one scenario the
    # admin controller actually exercises today.
    it "sets Current.user as the new Account's owner when present" do
      user = create(:user)
      Current.user = user

      org = described_class.create!(name: 'Admin Org With Current User Set')

      expect(org.account.owner).to eq(user)
    end

    it 'does not override an explicitly assigned Account' do
      existing_account = create(:account)

      org = described_class.create!(name: 'Admin Org With Account', account: existing_account)

      expect(org.account).to eq(existing_account)
    end

    it 'does not persist an orphan Account when the Organisation itself is invalid' do
      described_class.create!(name: 'Duplicate Admin Org Name')

      expect do
        described_class.new(name: 'Duplicate Admin Org Name').save
      end.not_to change(Account, :count)
    end
  end

  # =========================================================================
  # Scopes
  # =========================================================================

  describe 'scopes' do
    let!(:org_a) { described_class.create!(name: 'Alpha', domain: 'alpha.com', subdomain: 'alpha') }
    let!(:org_b) { described_class.create!(name: 'Beta', subdomain: 'beta') }
    let!(:org_c) { described_class.create!(name: 'Gamma') }

    describe '.ordered_by_name' do
      it 'orders alphabetically by name' do
        result = described_class.ordered_by_name.where(id: [org_a, org_b, org_c].map(&:id))
        expect(result.map(&:name)).to eq(%w[Alpha Beta Gamma])
      end
    end

    describe '.ordered_by_creation' do
      it 'orders by created_at' do
        result = described_class.ordered_by_creation.where(id: [org_a, org_b, org_c].map(&:id))
        expect(result.first).to eq(org_a)
        expect(result.last).to eq(org_c)
      end
    end

    describe '.with_domain' do
      it 'returns only organisations with a non-empty domain' do
        result = described_class.with_domain.where(id: [org_a, org_b, org_c].map(&:id))
        expect(result).to contain_exactly(org_a)
      end
    end

    describe '.with_subdomain' do
      it 'returns only organisations with a non-empty subdomain' do
        result = described_class.with_subdomain.where(id: [org_a, org_b, org_c].map(&:id))
        expect(result).to contain_exactly(org_a, org_b)
      end
    end
  end

  # =========================================================================
  # display_name
  # =========================================================================

  describe '#display_name' do
    it 'returns the name when present' do
      expect(organisation.display_name).to eq('Test Org')
    end

    it 'falls back to truncated UUID when name is blank' do
      organisation.name = ''
      expect(organisation.display_name).to start_with('Organisation ')
      expect(organisation.display_name).to eq("Organisation #{organisation.id.slice(0, 8)}")
    end

    it 'handles nil name on persisted record' do
      # Bypass validation to simulate legacy data
      organisation.update_column(:name, nil)
      organisation.reload
      expect(organisation.display_name).to eq("Organisation #{organisation.id.slice(0, 8)}")
    end

    it 'handles unsaved record with nil id gracefully' do
      org = described_class.new(name: nil)
      expect(org.display_name).to eq('Organisation ')
    end
  end

  # =========================================================================
  # domain_info
  # =========================================================================

  describe '#domain_info' do
    it 'returns combined domain and subdomain info' do
      expect(organisation.domain_info).to eq('Domain: test.local | Subdomain: test')
    end

    it 'returns only domain info when subdomain is nil' do
      organisation.subdomain = nil
      expect(organisation.domain_info).to eq('Domain: test.local')
    end

    it 'returns only subdomain info when domain is nil' do
      organisation.domain = nil
      expect(organisation.domain_info).to eq('Subdomain: test')
    end

    it 'returns empty string when both are nil' do
      organisation.domain = nil
      organisation.subdomain = nil
      expect(organisation.domain_info).to eq('')
    end

    it 'returns empty string when both are empty strings' do
      organisation.domain = ''
      organisation.subdomain = ''
      expect(organisation.domain_info).to eq('')
    end
  end

  # =========================================================================
  # full_url
  # =========================================================================

  describe '#full_url' do
    it 'returns domain when present' do
      expect(organisation.full_url).to eq('test.local')
    end

    it 'returns subdomain.example.com when only subdomain is present' do
      organisation.domain = nil
      expect(organisation.full_url).to eq('test.example.com')
    end

    it 'prefers domain over subdomain' do
      expect(organisation.full_url).to eq('test.local')
    end

    it 'returns nil when neither domain nor subdomain are present' do
      organisation.domain = nil
      organisation.subdomain = nil
      expect(organisation.full_url).to be_nil
    end

    it 'returns nil when both are empty strings' do
      organisation.domain = ''
      organisation.subdomain = ''
      expect(organisation.full_url).to be_nil
    end
  end

  # =========================================================================
  # Statistik-Methoden (membership-basiert)
  # =========================================================================

  describe 'membership statistics' do
    let(:user_a) { create(:user) }
    let(:user_b) { create(:user) }
    let(:user_c) { create(:user) }

    before do
      # Active memberships
      Admin::Membership.create!(organisation: organisation, user_id: user_a.id, active: true)
      Admin::Membership.create!(organisation: organisation, user_id: user_b.id, active: true)
      # Inactive membership
      Admin::Membership.create!(organisation: organisation, user_id: user_c.id, active: false)
    end

    describe '#total_users_count' do
      it 'counts all unique users with memberships' do
        expect(organisation.total_users_count).to eq(3)
      end

      it 'returns 0 when no memberships exist' do
        empty_org = described_class.create!(name: 'Empty Org')
        expect(empty_org.total_users_count).to eq(0)
      end
    end

    describe '#active_users_count' do
      it 'counts only active memberships' do
        expect(organisation.active_users_count).to eq(2)
      end
    end

    describe '#inactive_users_count' do
      it 'counts only inactive memberships' do
        expect(organisation.inactive_users_count).to eq(1)
      end

      it 'returns 0 when all users are active' do
        Admin::Membership.where(organisation: organisation, active: false).update_all(active: true)
        expect(organisation.inactive_users_count).to eq(0)
      end

      it 'returns 0 when no memberships exist' do
        empty_org = described_class.create!(name: 'Empty Org 2')
        expect(empty_org.inactive_users_count).to eq(0)
      end
    end

    describe '#total_projects_count' do
      it 'counts projects in the organisation' do
        Admin::Project.create!(name: 'Projekt A', organisation: organisation, settings: {})
        Admin::Project.create!(name: 'Projekt B', organisation: organisation, settings: {})
        expect(organisation.total_projects_count).to eq(2)
      end

      it 'returns 0 with no projects' do
        expect(organisation.total_projects_count).to eq(0)
      end
    end

    describe '#admin_users_count' do
      it 'counts memberships with account_admin role' do
        admin_role = Admin::Role.create!(
          organisation: organisation,
          title: ::Role::ACCOUNT_ADMIN_TITLE,
          description: 'Admin'
        )
        Admin::Membership.find_by(organisation: organisation, user_id: user_a.id)
                         .update!(role: admin_role)

        expect(organisation.admin_users_count).to eq(1)
      end

      it 'returns 0 when no admins exist' do
        expect(organisation.admin_users_count).to eq(0)
      end
    end
  end

  # =========================================================================
  # Membership-Hilfsmethoden
  # =========================================================================

  describe '#membership_for_user' do
    let(:user) { create(:user) }

    it 'returns the membership for a given user' do
      membership = Admin::Membership.create!(organisation: organisation, user_id: user.id, active: true)
      expect(organisation.membership_for_user(user.id)).to eq(membership)
    end

    it 'returns nil when user has no membership' do
      expect(organisation.membership_for_user(user.id)).to be_nil
    end
  end

  describe '#has_active_user?' do
    let(:user) { create(:user) }

    it 'returns true for active member' do
      Admin::Membership.create!(organisation: organisation, user_id: user.id, active: true)
      expect(organisation.has_active_user?(user.id)).to be true
    end

    it 'returns false for inactive member' do
      Admin::Membership.create!(organisation: organisation, user_id: user.id, active: false)
      expect(organisation.has_active_user?(user.id)).to be false
    end

    it 'returns false for non-member' do
      expect(organisation.has_active_user?(user.id)).to be false
    end
  end

  describe '#memberships_with_details' do
    it 'returns memberships ordered by user email with preloaded associations' do
      user_z = create(:user, email: 'zz@example.com')
      user_a = create(:user, email: 'aa@example.com')
      Admin::Membership.create!(organisation: organisation, user_id: user_z.id, active: true)
      Admin::Membership.create!(organisation: organisation, user_id: user_a.id, active: true)

      result = organisation.memberships_with_details
      expect(result.map(&:user_id)).to eq([user_a.id, user_z.id])
    end
  end

  # =========================================================================
  # AI-Konfiguration
  # =========================================================================

  describe '#ai_provider_info' do
    it 'returns provider info with organization id' do
      organisation.ai_provider = 'openai'
      organisation.ai_organization_id = 'org-123'
      expect(organisation.ai_provider_info).to eq('Openai (org-123)')
    end

    it 'returns provider info without organization id' do
      organisation.ai_provider = 'openai'
      organisation.ai_organization_id = nil
      expect(organisation.ai_provider_info).to eq('Openai')
    end

    it 'returns fallback when ai_provider is blank' do
      organisation.ai_provider = nil
      expect(organisation.ai_provider_info).to eq('Kein AI Provider')
    end

    it 'returns fallback when ai_provider is empty string' do
      organisation.ai_provider = ''
      expect(organisation.ai_provider_info).to eq('Kein AI Provider')
    end
  end

  describe '#ai_configured?' do
    it 'returns true when both token and provider are present' do
      organisation.ai_access_token = 'sk-test-token-123456'
      organisation.ai_provider = 'openai'
      expect(organisation.ai_configured?).to be true
    end

    it 'returns false when token is missing' do
      organisation.ai_access_token = nil
      organisation.ai_provider = 'openai'
      expect(organisation.ai_configured?).to be false
    end

    it 'returns false when provider is missing' do
      organisation.ai_access_token = 'sk-test-token-123456'
      organisation.ai_provider = nil
      expect(organisation.ai_configured?).to be false
    end

    it 'returns false when both are missing' do
      organisation.ai_access_token = nil
      organisation.ai_provider = nil
      expect(organisation.ai_configured?).to be false
    end
  end

  describe '#has_own_ai_credentials?' do
    it 'returns true when ai_access_token is present' do
      organisation.ai_access_token = 'sk-test-token-123456'
      expect(organisation.has_own_ai_credentials?).to be true
    end

    it 'returns false when ai_access_token is nil' do
      organisation.ai_access_token = nil
      expect(organisation.has_own_ai_credentials?).to be false
    end

    it 'returns false when ai_access_token is empty string' do
      organisation.ai_access_token = ''
      expect(organisation.has_own_ai_credentials?).to be false
    end

    # Mirror of ::Organisation, and load-bearing: Lalabase::Llm::Factory asks
    # this question provider-aware (#organisation_has_own?), so the arity-less
    # variant raised ArgumentError as soon as an admin surface routed through
    # the factory — which Admin::AiRoutingSummary now does on every row.
    it 'accepts a provider argument like the regular model' do
      organisation.ai_access_token = 'sk-test-token-123456'
      organisation.ai_provider = 'openai'

      expect { organisation.has_own_ai_credentials?('openai') }.not_to raise_error
      expect(organisation.has_own_ai_credentials?('openai')).to be true
    end

    it 'returns false for a provider the stored token does not belong to' do
      organisation.ai_access_token = 'sk-test-token-123456'
      organisation.ai_provider = 'anthropic'

      expect(organisation.has_own_ai_credentials?('openai')).to be false
    end
  end

  # S1: names come from AiCredential.provider_display_names — the ONE source —
  # so admin and app display can never diverge again.
  describe '#ai_provider_display_name' do
    it 'returns display name for known providers' do
      organisation.ai_provider = 'openai'
      expect(organisation.ai_provider_display_name).to eq('OpenAI (GPT)')
    end

    it 'returns display name for anthropic' do
      organisation.ai_provider = 'anthropic'
      expect(organisation.ai_provider_display_name).to eq('Anthropic (Claude)')
    end

    it 'returns display name for google' do
      organisation.ai_provider = 'google'
      expect(organisation.ai_provider_display_name).to eq('Google (Gemini)')
    end

    it 'capitalizes unknown providers' do
      organisation.ai_provider = 'cohere'
      expect(organisation.ai_provider_display_name).to eq('Cohere')
    end

    it 'returns Standard when provider is nil' do
      organisation.ai_provider = nil
      expect(organisation.ai_provider_display_name).to eq('Standard')
    end
  end

  # =========================================================================
  # masked_ai_token
  # =========================================================================

  describe '#masked_ai_token' do
    it 'returns nil when no token is present' do
      organisation.ai_access_token = nil
      expect(organisation.masked_ai_token).to be_nil
    end

    it 'returns nil when token is empty string' do
      organisation.ai_access_token = ''
      expect(organisation.masked_ai_token).to be_nil
    end

    it 'masks openai token with sk- prefix' do
      organisation.ai_provider = 'openai'
      organisation.ai_access_token = 'sk-abcdefghijklmnopqrstuvwxyz1234567890ABCD12345678'
      result = organisation.masked_ai_token
      expect(result).to start_with('sk-')
      expect(result).to end_with('12345678')
      expect(result).to include('*' * 40)
    end

    it 'masks anthropic token with sk-ant- prefix' do
      organisation.ai_provider = 'anthropic'
      organisation.ai_access_token = 'sk-ant-abcdefghijklmnopqrstuvwxyz1234567890ABCD12345678'
      result = organisation.masked_ai_token
      expect(result).to start_with('sk-ant-')
      expect(result).to end_with('12345678')
      expect(result).to include('*' * 80)
    end

    it 'uses generic mask for unknown providers' do
      organisation.ai_provider = 'cohere'
      organisation.ai_access_token = 'cohere-token-abcdefghijklmnop12345678'
      result = organisation.masked_ai_token
      expect(result).to start_with('*' * 40)
      expect(result).to end_with('12345678')
    end

    it 'defaults to openai masking when provider is nil' do
      organisation.ai_provider = nil
      organisation.ai_access_token = 'some-token-abcdefghijklmnop12345678'
      result = organisation.masked_ai_token
      expect(result).to start_with('sk-')
    end

    it 'handles short tokens without raising' do
      organisation.ai_provider = 'openai'
      organisation.ai_access_token = 'short'
      result = organisation.masked_ai_token
      expect(result).to be_a(String)
      expect(result).to include('short')
    end
  end

  # =========================================================================
  # AI-Usage Statistiken
  # =========================================================================

  describe 'AI usage statistics' do
    before do
      # Recent usage (within 30 days)
      Admin::AiUsage.create!(
        organisation: organisation,
        provider: 'openai',
        tokens_used: 1000,
        cost_cents: 5,
        used_at: 5.days.ago
      )
      Admin::AiUsage.create!(
        organisation: organisation,
        provider: 'openai',
        tokens_used: 2000,
        cost_cents: 10,
        used_at: 10.days.ago
      )
      # Old usage (beyond 30 days)
      Admin::AiUsage.create!(
        organisation: organisation,
        provider: 'openai',
        tokens_used: 5000,
        cost_cents: 25,
        used_at: 60.days.ago
      )
    end

    describe '#total_ai_usage_tokens' do
      it 'sums all tokens across all time' do
        expect(organisation.total_ai_usage_tokens).to eq(8000)
      end
    end

    describe '#total_ai_usage_cost_cents' do
      it 'sums all costs across all time' do
        expect(organisation.total_ai_usage_cost_cents).to eq(40)
      end
    end

    describe '#recent_ai_usage_tokens' do
      it 'sums tokens within default 30 days' do
        expect(organisation.recent_ai_usage_tokens).to eq(3000)
      end

      it 'accepts custom days parameter' do
        expect(organisation.recent_ai_usage_tokens(7)).to eq(1000)
      end

      it 'returns 0 when no recent usage exists' do
        expect(organisation.recent_ai_usage_tokens(1)).to eq(0)
      end
    end

    describe '#recent_ai_usage_cost_cents' do
      it 'sums cost within default 30 days' do
        expect(organisation.recent_ai_usage_cost_cents).to eq(15)
      end

      it 'accepts custom days parameter' do
        expect(organisation.recent_ai_usage_cost_cents(7)).to eq(5)
      end
    end

    context 'with no ai_usages' do
      let(:empty_org) { described_class.create!(name: 'Empty AI Org') }

      it 'returns 0 for total_ai_usage_tokens' do
        expect(empty_org.total_ai_usage_tokens).to eq(0)
      end

      it 'returns 0 for total_ai_usage_cost_cents' do
        expect(empty_org.total_ai_usage_cost_cents).to eq(0)
      end

      it 'returns 0 for recent_ai_usage_tokens' do
        expect(empty_org.recent_ai_usage_tokens).to eq(0)
      end

      it 'returns 0 for recent_ai_usage_cost_cents' do
        expect(empty_org.recent_ai_usage_cost_cents).to eq(0)
      end
    end
  end

  # =========================================================================
  # find_or_create_account_admin_role
  # =========================================================================

  describe '#find_or_create_account_admin_role' do
    it 'creates a new admin role when none exists' do
      expect do
        role = organisation.find_or_create_account_admin_role
        expect(role.title).to eq(::Role::ACCOUNT_ADMIN_TITLE)
        expect(role.description).to eq('Administrator mit vollen Zugriffsrechten')
        expect(role.is_default).to be false
      end.to change { Admin::Role.where(organisation: organisation).count }.by(1)
    end

    it 'returns existing admin role when one already exists' do
      existing = Admin::Role.create!(
        organisation: organisation,
        title: ::Role::ACCOUNT_ADMIN_TITLE,
        description: 'Existing admin'
      )

      expect do
        role = organisation.find_or_create_account_admin_role
        expect(role).to eq(existing)
      end.not_to(change { Admin::Role.where(organisation: organisation).count })
    end

    it 'is idempotent - multiple calls return the same role' do
      role1 = organisation.find_or_create_account_admin_role
      role2 = organisation.find_or_create_account_admin_role
      expect(role1.id).to eq(role2.id)
    end

    it 'does not affect admin roles in other organisations' do
      other_org = described_class.create!(name: 'Other Org')
      organisation.find_or_create_account_admin_role
      other_org.find_or_create_account_admin_role

      expect(Admin::Role.where(title: ::Role::ACCOUNT_ADMIN_TITLE).count).to eq(2)
    end
  end

  # =========================================================================
  # Encryption
  # =========================================================================

  describe 'encryption' do
    it 'encrypts ai_access_token' do
      org = described_class.create!(name: 'Encrypted Org', ai_access_token: 'sk-secret-token-12345')
      org.reload

      # The token should be retrievable
      expect(org.ai_access_token).to eq('sk-secret-token-12345')

      # But stored encrypted in the database
      raw_value = ActiveRecord::Base.connection.select_value(
        "SELECT ai_access_token FROM organisations WHERE id = '#{org.id}'"
      )
      expect(raw_value).not_to eq('sk-secret-token-12345')
    end
  end

  # =========================================================================
  # Multi-tenancy bypass
  # =========================================================================

  describe 'multi-tenancy bypass' do
    it 'does not scope queries by tenant' do
      org1 = described_class.create!(name: 'Org One')
      org2 = described_class.create!(name: 'Org Two')

      # Admin::Organisation should see all orgs without tenant scoping
      all_orgs = described_class.where(id: [org1.id, org2.id])
      expect(all_orgs.count).to eq(2)
    end

    it 'can read records created by the regular Organisation model' do
      regular_org = Organisation.create!(name: 'Regular Org')
      admin_org = described_class.find(regular_org.id)
      expect(admin_org.name).to eq('Regular Org')
    end
  end
end
