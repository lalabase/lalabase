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

RSpec.describe Organisation, type: :model do
  describe 'associations' do
    it { should have_many(:memberships).dependent(:destroy) }
    it { should have_many(:users).through(:memberships) }
    it { should have_many(:invitations).dependent(:destroy) }
    it { should have_many(:roles).dependent(:destroy) }
    it { should have_many(:projects).dependent(:destroy) }
    it { should belong_to(:account).optional }
  end

  # Embedding dimension is a first-class part of the vector-space triple
  # (doc/embedding_v2_multidim_plan.md §3.2). PR 1 gates it to nil or 1536; the
  # other SUPPORTED_DIMS (768/1024) stay locked until PR 5 provides their storage.
  describe 'embedding_dims validation (v2 §3.2)' do
    it 'allows nil (unconfigured → system default 1536)' do
      expect(build(:organisation, embedding_dims: nil)).to be_valid
    end

    # Sharp since PR 5: every SUPPORTED_DIMS value has its own storage lane and ANN
    # index on the sidecar. Iterated over the CONSTANT rather than a literal list, so
    # a future lane cannot be added without a matching positive case landing here.
    described_class::SUPPORTED_DIMS.each do |dims|
      it "allows #{dims} (has its own sidecar index lane since PR 5)" do
        expect(build(:organisation, embedding_dims: dims)).to be_valid
      end
    end

    # 3072 used to sit here as "the one REAL value that stays out until PR 5b (own halfvec
    # index mechanics)". PR 5b shipped that lane, so 3072 belongs in the positive loop above —
    # where it landed on its own, exactly as that loop was built to do. 999 stays as the
    # plain-typo guard, so an allowlist that silently swallows anything still breaks here.
    [999].each do |dims|
      it "rejects #{dims} (outside SUPPORTED_DIMS)" do
        org = build(:organisation, embedding_dims: dims)
        expect(org).not_to be_valid
        expect(org.errors[:embedding_dims]).to be_present
      end
    end

    # Deliberately a literal, not the constant: widening the allowlist has to be a conscious
    # act that shows up in a diff, not something the spec agrees to by construction.
    it 'exposes exactly the shipped allowlist as SUPPORTED_DIMS' do
      expect(described_class::SUPPORTED_DIMS).to eq([768, 1024, 1536, 3072])
    end
  end

  describe '#ensure_account (Plan doc/billing_agentur_konto_plan.md D8)' do
    after { Current.user = nil }

    it 'auto-creates a 1:1 Account on organisation creation' do
      org = create(:organisation)

      expect(org.account).to be_present
      expect(org.account.name).to eq(org.name)
    end

    it "sets Current.user as the new Account's owner when present" do
      user = create(:user)
      Current.user = user

      org = create(:organisation)

      expect(org.account.owner).to eq(user)
    end

    it 'leaves the Account owner-less when Current.user is nil (factories/rake tasks)' do
      Current.user = nil

      org = create(:organisation)

      expect(org.account.owner).to be_nil
    end

    it 'does not override an explicitly assigned Account' do
      existing_account = create(:account)

      org = create(:organisation, account: existing_account)

      expect(org.account).to eq(existing_account)
      expect(Account.count).to eq(1)
    end

    it 'does not persist an orphan Account when the Organisation itself is invalid' do
      create(:organisation, name: 'Duplicate Name')

      expect do
        build(:organisation, name: 'Duplicate Name').save
      end.not_to change(Account, :count)
    end
  end

  describe 'validations' do
    it { should validate_presence_of(:name) }

    it 'validates uniqueness of name' do
      create(:organisation, name: 'Unique Org')
      org = build(:organisation, name: 'Unique Org')
      expect(org).not_to be_valid
      expect(org.errors[:name]).to be_present
    end

    it 'creates an organisation with expected attributes' do
      org = create(:organisation)
      expect(org.name).to start_with('Test Organisation')
      expect(org.subdomain).to eq('test')
      expect(org.domain).to eq('test.local')
    end
  end

  # S1 honest facade: the org chat provider must be Factory-buildable. The rule
  # is conditional (only on set/change) so legacy rows survive unrelated saves.
  describe 'ai_provider inclusion (S1 honest facade)' do
    it 'accepts every provider the Factory can build' do
      AiCredential.implemented_providers.each do |provider|
        org = build(:organisation, ai_provider: provider)
        expect(org).to be_valid, "expected ai_provider=#{provider} to be valid"
      end
    end

    it 'accepts a blank ai_provider (falls back to openai at routing time)' do
      expect(build(:organisation, ai_provider: nil)).to be_valid
    end

    it 'accepts google (implemented since the GoogleVertexProvider slice)' do
      expect(build(:organisation, ai_provider: 'google')).to be_valid
    end

    it 'rejects the removed cohere provider and unknown strings on create' do
      expect(build(:organisation, ai_provider: 'cohere')).not_to be_valid
      expect(build(:organisation, ai_provider: 'made_up')).not_to be_valid
    end

    it 'rejects switching an existing org onto an unimplemented provider' do
      org = create(:organisation, ai_provider: 'openai')
      org.ai_provider = 'cohere'
      expect(org).not_to be_valid
      expect(org.errors[:ai_provider]).to be_present
    end

    it 'tolerates a persisted legacy value on unrelated saves' do
      org = create(:organisation, ai_provider: 'openai')
      # Force a legacy value past the validation, mimicking a pre-S1 row.
      org.update_column(:ai_provider, 'cohere')

      org.name = "#{org.name} (renamed)"
      expect(org).to be_valid # ai_provider not changing -> rule does not fire
    end
  end

  describe '#active_memberships' do
    let(:organisation) { create(:organisation) }
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, organisation: organisation, user: user1, active: true)
        create(:membership, organisation: organisation, user: user2, active: false)
      end
    end

    it 'returns only active memberships' do
      expect(organisation.active_memberships.count).to eq(1)
      expect(organisation.active_memberships.first.user).to eq(user1)
    end
  end

  describe '#active_users' do
    let(:organisation) { create(:organisation) }
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, organisation: organisation, user: user1, active: true)
        create(:membership, organisation: organisation, user: user2, active: false)
      end
    end

    it 'returns only users with active memberships' do
      expect(organisation.active_users.count).to eq(1)
      expect(organisation.active_users.first).to eq(user1)
    end
  end

  describe '#find_or_create_default_role' do
    context 'when a default role exists' do
      let(:organisation) { create(:organisation) }
      let!(:default_role) do
        ActsAsTenant.with_tenant(organisation) do
          create(:role, organisation: organisation, is_default: true, title: 'Default Role')
        end
      end

      it 'returns the existing default role' do
        ActsAsTenant.with_tenant(organisation) do
          expect(organisation.find_or_create_default_role).to eq(default_role)
        end
      end

      it 'does not create a new role' do
        ActsAsTenant.with_tenant(organisation) do
          expect { organisation.find_or_create_default_role }.not_to change(Role, :count)
        end
      end
    end

    context 'when no default role exists' do
      let(:organisation) { create(:organisation) }

      it 'creates a new default role' do
        ActsAsTenant.with_tenant(organisation) do
          expect { organisation.find_or_create_default_role }.to change(Role, :count).by(1)
        end
      end

      it 'returns a role with correct attributes' do
        ActsAsTenant.with_tenant(organisation) do
          role = organisation.find_or_create_default_role
          expect(role.title).to eq('Standard-Benutzer')
          expect(role.description).to eq('Standardrolle für neue Benutzer')
          expect(role.is_default).to be true
        end
      end
    end
  end

  describe '#find_or_create_account_admin_role' do
    context 'when an admin role exists' do
      let(:organisation) { create(:organisation) }
      let!(:admin_role) do
        ActsAsTenant.with_tenant(organisation) do
          create(:role, organisation: organisation, title: 'account_admin')
        end
      end

      it 'returns the existing admin role' do
        ActsAsTenant.with_tenant(organisation) do
          expect(organisation.find_or_create_account_admin_role).to eq(admin_role)
        end
      end

      it 'does not create a new role' do
        ActsAsTenant.with_tenant(organisation) do
          expect { organisation.find_or_create_account_admin_role }.not_to change(Role, :count)
        end
      end
    end

    context 'when no admin role exists' do
      let(:organisation) { create(:organisation) }

      it 'creates a new admin role' do
        ActsAsTenant.with_tenant(organisation) do
          expect { organisation.find_or_create_account_admin_role }.to change(Role, :count).by(1)
        end
      end

      it 'returns a role with correct attributes' do
        ActsAsTenant.with_tenant(organisation) do
          role = organisation.find_or_create_account_admin_role
          expect(role.title).to eq('account_admin')
          expect(role.description).to eq('Administrator mit vollen Zugriffsrechten')
          expect(role.is_default).to be false
        end
      end
    end
  end

  describe 'lifecycle hooks' do
    describe 'when creating an organisation' do
      it 'can have users associated through memberships' do
        organisation = create(:organisation)
        user = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, organisation: organisation, user: user, active: true)
        end

        expect(organisation.users).to include(user)
      end
    end

    describe 'when destroying an organisation' do
      let(:organisation) { create(:organisation) }
      let!(:user) { create(:user) }
      let!(:role) do
        ActsAsTenant.with_tenant(organisation) do
          create(:role, organisation: organisation)
        end
      end
      let!(:membership) do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, organisation: organisation, user: user, role: role)
        end
      end
      let!(:project) do
        ActsAsTenant.with_tenant(organisation) do
          create(:project, organisation: organisation)
        end
      end
      let!(:invitation) do
        ActsAsTenant.with_tenant(organisation) do
          create(:invitation, organisation: organisation)
        end
      end

      it 'destroys dependent memberships' do
        ActsAsTenant.with_tenant(organisation) do
          expect do
            organisation.destroy
          end.to change(Membership, :count).by(-1)
        end
      end

      it 'destroys dependent roles' do
        ActsAsTenant.with_tenant(organisation) do
          # Check how many roles exist before destroy
          initial_count = Role.count
          expect(initial_count).to eq(1)

          expect do
            organisation.destroy
          end.to change(Role, :count).by(-initial_count)
        end
      end

      it 'destroys dependent projects' do
        ActsAsTenant.with_tenant(organisation) do
          expect do
            organisation.destroy
          end.to change(Project, :count).by(-1)
        end
      end

      it 'destroys dependent invitations' do
        ActsAsTenant.with_tenant(organisation) do
          expect do
            organisation.destroy
          end.to change(Invitation, :count).by(-1)
        end
      end

      it 'does not destroy users' do
        ActsAsTenant.with_tenant(organisation) do
          expect do
            organisation.destroy
          end.not_to change(User, :count)
        end
      end
    end
  end

  describe 'multi-tenancy behavior' do
    let(:organisation1) { create(:organisation) }
    let(:organisation2) { create(:organisation) }

    it 'isolates roles between organisations' do
      ActsAsTenant.with_tenant(organisation1) do
        create(:role, organisation: organisation1, title: 'Shared Role Name')
      end

      # Should be able to create a role with the same title in a different org
      ActsAsTenant.with_tenant(organisation2) do
        role2 = build(:role, organisation: organisation2, title: 'Shared Role Name')
        expect(role2).to be_valid
      end
    end

    it 'allows each organisation to have its own set of projects' do
      ActsAsTenant.with_tenant(organisation1) do
        project1 = create(:project, organisation: organisation1, name: 'Project Alpha')
        expect(organisation1.projects).to include(project1)
      end

      ActsAsTenant.with_tenant(organisation2) do
        project2 = create(:project, organisation: organisation2, name: 'Project Beta')
        expect(organisation2.projects).to include(project2)
      end

      ActsAsTenant.with_tenant(organisation1) do
        expect(organisation1.projects.count).to eq(1)
      end

      ActsAsTenant.with_tenant(organisation2) do
        expect(organisation2.projects.count).to eq(1)
      end
    end
  end

  describe 'data_import_enabled (per-organisation operator gate for the CodebaseHQ import)' do
    it 'defaults to false on insert — the importer stays dark until an operator enables it' do
      # NOT set via factory → this exercises the DB column default, which is what
      # CodebaseImportFilePolicy#import_permitted? and the settings tab gate read.
      expect(create(:organisation).reload.data_import_enabled).to be(false)
    end
  end

  # The operator switch for the code index (CodeIndexingGated). Step 4 of
  # doc/projekt_chat_abbau_plan.md renamed the column it reads from
  # `project_chat_enabled` to `code_indexing_enabled` in three releases; this is
  # release 2, where the predicate reads the new column alone and the old one is in
  # ignored_columns.
  #
  # ⚠️ The old column is asserted as ABSENT from the model, in both directions: gone
  # from column_names (nothing SELECTs it, which is what makes release 3's DROP safe)
  # and still present in the DATABASE (release 3 has not run). Release 1 pinned the OR
  # here instead; that had to change with the code, which is the point of pinning it.
  describe '#code_indexing? (operator switch)' do
    it 'defaults to false on insert — feature off until an operator enables it' do
      # NOT set via factory → this exercises the DB column default, the real
      # contract the gate relies on. Flipping the migration default breaks it.
      organisation = create(:organisation).reload

      expect(organisation.code_indexing_enabled).to be(false)
      expect(organisation.code_indexing?).to be(false)
    end

    it 'is true from the new column' do
      expect(create(:organisation, code_indexing_enabled: true).code_indexing?).to be(true)
    end

    it 'ignores the old column: the model cannot see it, the database still has it' do
      expect(Organisation.column_names).not_to include('project_chat_enabled')
      expect(Organisation.connection.columns(:organisations).map(&:name))
        .to include('project_chat_enabled')
    end

    # ⚠️ Admin::Organisation is a SEPARATE class over the same table, and the admin
    # toggle reads this predicate. A switch declared on the tenant-side twin alone is
    # the mistake admin_twin_concern_parity_guard_spec exists for -- it happened three
    # times before. Asked here rather than only in the guard, because the guard checks
    # that the concern is included, not that it answers the same.
    it 'answers identically on the admin twin, which shares the concern' do
      organisation = create(:organisation, code_indexing_enabled: true)
      twin = Admin::Organisation.find(organisation.id)

      expect(twin.code_indexing?).to be(true)
      expect(Admin::Organisation.include?(CodeIndexingGated)).to be(true)
      # The twin has to ignore the old column too, or release 3's DROP breaks the
      # operator's path while leaving the tenant side fine.
      expect(Admin::Organisation.column_names).not_to include('project_chat_enabled')
    end
  end

  # GDPR org-level AI opt-in (audit 2026-07-03, item 1.2). The DB default and
  # the legacy-seam gate are the two model-level halves of the contract; the
  # factory seam is covered in spec/services/lalabase/llm/factory_spec.rb.
  describe 'ai_enabled (GDPR org-level AI opt-in)' do
    it 'defaults to false on INSERT — no content leaves for an LLM provider until an admin opts in' do
      # Raw create! WITHOUT the factory (which enables AI for test convenience):
      # this exercises the real DB column default. Flipping the migration
      # default to true — the exact regression the audit exists for — breaks here.
      org = Organisation.create!(name: "opt-in default probe #{SecureRandom.hex(4)}")
      expect(org.reload.ai_enabled).to be(false)
    end

    it 'rejects NULL for ai_enabled at the DB layer (tri-state would soften the gate)' do
      # No model validation on purpose (boolean column) — the NOT NULL
      # constraint is the only guard against an "unknown" opt-in state.
      org = create(:organisation)
      expect { org.update!(ai_enabled: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'keeps activation history via ai_activated_at / ai_activated_by' do
      user = create(:user)
      org = create(:organisation, :ai_disabled)
      org.update!(ai_enabled: true, ai_activated_at: Time.current, ai_activated_by: user)
      expect(org.reload.ai_activated_by).to eq(user)
      expect(org.ai_activated_at).to be_present
    end

    it 'nullifies ai_activated_by when the activating user row is deleted (FK on_delete)' do
      # user.delete (raw SQL, no callbacks) hits the FK directly: without
      # on_delete: :nullify this raises InvalidForeignKey and account deletion
      # of a former admin would fail for the whole organisation.
      user = create(:user)
      org = create(:organisation, ai_enabled: true, ai_activated_at: Time.current, ai_activated_by: user)
      expect { user.delete }.not_to raise_error
      expect(org.reload.ai_activated_by_id).to be_nil
      expect(org.ai_enabled).to be(true) # history nulled, the opt-in itself survives
    end

    # The UI-advertising gate: BOTH halves must hold, in either order — a
    # mutation dropping either conjunct (showing buttons to non-opted-in orgs,
    # or to opted-in orgs without credentials) dies here.
    describe '#ai_available?' do
      it 'is true only when opted in AND a valid configuration exists' do
        org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                    ai_access_token: 'sk-test-1234567890abcdef')
        expect(org.ai_available?('openai')).to be(true)
      end

      it 'is false without the opt-in, even with valid credentials' do
        org = create(:organisation, :ai_disabled, ai_provider: 'openai',
                                                  ai_access_token: 'sk-test-1234567890abcdef')
        expect(org.ai_available?('openai')).to be(false)
      end

      it 'is false when opted in but no usable configuration exists' do
        org = create(:organisation, ai_enabled: true, ai_provider: 'openai', ai_access_token: nil)
        allow(AiCredential).to receive(:active_for_provider).and_return(nil)
        # has_valid_ai_configuration? falls back to credentials/ENV — pin BOTH
        # to absent, or this test flips red on any machine that exports
        # OPENAI_ACCESS_TOKEN (review finding: environment coupling).
        allow(Rails.application.credentials).to receive(:openai).and_return(nil)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('OPENAI_ACCESS_TOKEN').and_return(nil)

        expect(org.ai_available?('openai')).to be(false)
      end
    end

    # S1c (doc/ki_provider_reichweite_plan.md §2.1b). Before this slice the method
    # was `case provider … else false`: EVERY provider except 'openai' answered a
    # hard false, so an org on Mistral, Anthropic or Gemini saw no AI actions at
    # all and got a 403 on a direct POST — no matter how correctly the routing
    # underneath was configured. Each implemented provider therefore gets a
    # positive AND a negative case: restoring the `else false` kills every
    # positive one, dropping the checks kills every negative one.
    describe '#has_valid_ai_configuration? (provider-neutral since S1c)' do
      # No BYOK and no system credential unless an example sets one up — without
      # this the results would depend on whatever credentials the machine happens
      # to have (the environment-coupling finding one describe above).
      before { allow(AiCredential).to receive(:active_for_provider).and_return(nil) }

      def active_credential_for(provider, **attrs)
        credential = build_stubbed(:ai_credential, provider: provider, active: true, enabled: true, **attrs)
        allow(AiCredential).to receive(:active_for_provider).with(provider).and_return(credential)
      end

      context 'openai' do
        let(:org) { create(:organisation, ai_enabled: true, ai_provider: 'openai') }

        it 'accepts an own sk- token (the pre-S1c rule, unchanged)' do
          org.update!(ai_access_token: 'sk-org-own-1234567890abcdef')
          expect(org.has_valid_ai_configuration?('openai')).to be(true)
        end

        it 'rejects an own token in the wrong format — the ONE format we own' do
          org.update!(ai_access_token: 'definitely-not-an-openai-key-but-long')
          expect(org.has_valid_ai_configuration?('openai')).to be(false)
        end

        it 'accepts an active system credential when the org brought none' do
          active_credential_for('openai')
          expect(org.has_valid_ai_configuration?('openai')).to be(true)
        end

        it 'rejects when neither BYOK nor an active system credential exists' do
          expect(org.has_valid_ai_configuration?('openai')).to be(false)
        end
      end

      context 'anthropic' do
        let(:org) { create(:organisation, ai_enabled: true, ai_provider: 'anthropic') }

        it 'accepts an own token — no format guess, presence is all we can assert' do
          org.update!(ai_access_token: "sk-ant-#{'a' * 95}")
          expect(org.has_valid_ai_configuration?('anthropic')).to be(true)
        end

        it 'accepts an active system credential' do
          active_credential_for('anthropic')
          expect(org.has_valid_ai_configuration?('anthropic')).to be(true)
        end

        it 'rejects a system credential that is active but NOT enabled' do
          credential = build_stubbed(:ai_credential, provider: 'anthropic', active: true, enabled: false)
          allow(AiCredential).to receive(:active_for_provider).with('anthropic').and_return(credential)
          expect(org.has_valid_ai_configuration?('anthropic')).to be(false)
        end

        it 'rejects when nothing is configured' do
          expect(org.has_valid_ai_configuration?('anthropic')).to be(false)
        end
      end

      # The endpoint is a stranger's, so there is no key format to check — but two
      # settings are hard runtime raises in OpenAiCompatibleProvider, and the chat
      # columns (unlike the embedding ones) carry no presence validation. Without
      # these two conjuncts the gate would advertise a button that 500s.
      context 'openai_compatible' do
        let(:org) do
          create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                                ai_access_token: 'sk-mistral-own-token-1234567890',
                                ai_api_base: 'https://api.mistral.ai/v1',
                                preferred_chat_model: 'mistral-small-latest')
        end

        it 'accepts a complete BYOK setup (token + endpoint + model)' do
          expect(org.has_valid_ai_configuration?('openai_compatible')).to be(true)
        end

        it 'rejects a BYOK setup without an endpoint — the provider raises without one' do
          org.update!(ai_api_base: nil)
          expect(org.has_valid_ai_configuration?('openai_compatible')).to be(false)
        end

        it 'rejects a BYOK setup without a chat model — BYOK has no credential tier to fall back on' do
          org.update!(preferred_chat_model: nil)
          expect(org.has_valid_ai_configuration?('openai_compatible')).to be(false)
        end

        it 'accepts an active system credential when the org brought no token' do
          org.update!(ai_access_token: nil)
          active_credential_for('openai_compatible', default_model: 'mistral-small-latest',
                                                     api_base: 'https://api.mistral.ai/v1')
          expect(org.has_valid_ai_configuration?('openai_compatible')).to be(true)
        end

        # Found by the review of #391: the two halves of THIS gate disagreed. The
        # BYOK half (three examples above) demanded a model; the system half asked
        # only `enabled?` and waved through a credential that cannot name one. The
        # org then saw an offered button whose click died at
        # OpenAiCompatibleProvider#default_chat_model — it raises rather than
        # guessing, because there is no honest default for a stranger's endpoint.
        #
        # Reachable because Admin::AiCredential — the class the admin backend
        # actually writes through — did not require default_model (fixed in the same
        # PR). This branch is what covers the rows that ALREADY exist.
        it 'rejects a system credential without a model when the org names none either' do
          org.update!(ai_access_token: nil, preferred_chat_model: nil)
          active_credential_for('openai_compatible', default_model: nil,
                                                     api_base: 'https://api.mistral.ai/v1')

          expect(org.has_valid_ai_configuration?('openai_compatible')).to be(false)
        end

        # ⚠️ INVERTED in the review of S7, and the inversion is the point. This example
        # used to expect `true`, with the reasoning "the org's preferred_chat_model wins
        # over credential.default_model in Factory#resolve_credentials, so EITHER is
        # enough". The premise is gone: the org column no longer feeds the SYSTEM branch,
        # because it turned into a customer-editable field and was choosing the model
        # that runs on the operator's key.
        #
        # So the gate must not accept it either. A gate that answers about a value the
        # request does not read is the exact failure mode the neighbouring example
        # documents — "configured", then a click that dies in
        # OpenAiCompatibleProvider#default_chat_model.
        it 'still rejects a system credential without a model when only the ORG names one' do
          org.update!(ai_access_token: nil, preferred_chat_model: 'mistral-small-latest')
          active_credential_for('openai_compatible', default_model: nil,
                                                     api_base: 'https://api.mistral.ai/v1')

          expect(org.has_valid_ai_configuration?('openai_compatible')).to be(false)
        end
      end

      # Vertex is service-account-only: an API key would silently use the GLOBAL
      # endpoint and void EU data residency. The rule is REUSED from
      # AiCredentialProviderRules, so this also pins that it is not re-implemented.
      context 'google' do
        let(:org) { create(:organisation, ai_enabled: true, ai_provider: 'google') }
        let(:service_account_json) do
          { type: 'service_account', project_id: 'lala-eu',
            private_key: "-----BEGIN PRIVATE KEY-----\nMIItest\n-----END PRIVATE KEY-----\n",
            client_email: 'vertex@lala-eu.iam.gserviceaccount.com' }.to_json
        end

        # The likeliest way to get this method wrong while making it
        # provider-neutral: apply ONE token check to all providers. A
        # service-account JSON starts with '{', so a generically applied
        # sk-/org- rule would reject every google BYOK org — and the button
        # would vanish for a customer whose setup is perfectly valid. The
        # explicit non-sk- assertions below say out loud what is being pinned.
        it 'accepts an own service-account JSON — the sk-/org- rule must NOT apply here' do
          org.update!(ai_access_token: service_account_json)

          expect(service_account_json).not_to start_with('sk-')
          expect(service_account_json).not_to start_with('org-')
          expect(org.has_valid_ai_configuration?('google')).to be(true)
          expect(org.ai_available_for?(:meeting_summary)).to be_available
        end

        it 'rejects a plain API key (AIza…) — that would void EU residency' do
          org.update!(ai_access_token: 'AIzaSyDummyKeyThatIsLongEnough12345')
          expect(org.has_valid_ai_configuration?('google')).to be(false)
        end

        it 'rejects a service-account JSON missing client_email' do
          org.update!(ai_access_token: { type: 'service_account', private_key: 'x' }.to_json)
          expect(org.has_valid_ai_configuration?('google')).to be(false)
        end

        it 'rejects an sk- token on a google org — a valid OpenAI key is not a Vertex credential' do
          org.update!(ai_access_token: 'sk-org-own-1234567890abcdef')
          expect(org.has_valid_ai_configuration?('google')).to be(false)
        end

        it 'accepts an active system credential' do
          active_credential_for('google')
          expect(org.has_valid_ai_configuration?('google')).to be(true)
        end

        # --- The shape that is LIVE in production -------------------------------
        # Vertex runs in prod (europe-west3/-west1, gemini-2.5-flash) off an active
        # system credential of type google; the orgs on it carry no BYOK token.
        # These two examples are the deploy-relevant pair: the first must not kip
        # over, the second is the defect S1c fixes.
        #
        # R2 removed the ai_available_for_chat? facade these examples asked; they now
        # name a FEATURE. :meeting_summary is not arbitrary — the meetings actions are
        # where the 403 was actually observed, and prod is exactly this shape
        # (Vertex/europe-west3, gemini-2.5-flash, no BYOK). Every unpinned chat feature
        # answers identically, so the S1c regression is unchanged in substance.
        context 'the production shape: no BYOK, active google system credential' do
          before do
            allow(AiCredential).to receive(:active_for_provider).and_call_original
            create(:ai_credential, :google, :active)
          end

          it 'stays available — S1c must not take the feature away from a live Vertex org' do
            expect(org.ai_access_token).to be_blank
            expect(org.has_valid_ai_configuration?('google')).to be(true)
            expect(org.ai_available_for?(:meeting_summary)).to be_available
          end

          it 'answers for GOOGLE, not for whatever OpenAI credential happens to exist' do
            # The pre-S1c views asked ai_available?('openai'), so a Vertex org's
            # buttons hung on a FOREIGN credential. Now the two questions are
            # independent — and the feature gate follows the org.
            expect(org.chat_provider_name).to eq('google')
            expect(org.has_valid_ai_configuration?('openai')).to be(false)
            expect(org.ai_available_for?(:meeting_summary)).to be_available
          end
        end

        # THE INTENDED CORRECTION, NOT A REGRESSION.
        #
        # Before S1c the views asked ai_available?('openai'), which for this org
        # answered TRUE — purely because an unrelated OpenAI system credential
        # existed. The org saw its AI buttons, clicked, and only then hit
        # Factory::MissingCredentialError ("No active credential configured for
        # provider \"google\"") in the job. After S1c the gate answers the question
        # that is actually being asked, so the button is withheld instead.
        #
        # Deploy consequence: an org on 'google' WITHOUT an active google
        # credential loses buttons that never worked. If such an org exists in
        # prod, the fix is to activate its credential — not to revert this.
        context 'org on google but only an OpenAI credential is active (misconfiguration)' do
          before do
            allow(AiCredential).to receive(:active_for_provider).and_call_original
            create(:ai_credential, :active, provider: 'openai')
          end

          it 'is false — and the pre-S1c openai question would have said true' do
            expect(org.has_valid_ai_configuration?('google')).to be(false)
            expect(org.ai_available_for?(:meeting_summary)).not_to be_available
            # The exact expression the views used before S1c, still answering true:
            expect(org.ai_available?('openai')).to be(true)
          end

          it 'would have failed at the seam, so withholding the button is the honest answer' do
            expect { Lalabase::Llm::Factory.for_chat(org) }
              .to raise_error(Lalabase::Llm::Factory::MissingCredentialError, /google/)
          end
        end
      end

      # Honest facade: the Factory cannot build these, so no gate may open for
      # them — the legacy values a long-lived org may still carry.
      it 'rejects a provider the Factory cannot build (legacy cohere row)' do
        org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                    ai_access_token: 'sk-org-own-1234567890abcdef')
        expect(AiCredential.implemented_providers).not_to include('cohere')
        expect(org.has_valid_ai_configuration?('cohere')).to be(false)
      end

      it 'never falls back to a system credential once the org brought its own token' do
        # Mirrors Factory#resolve_credentials, which takes the org token and never
        # consults the system tier — answering "available" off a credential the
        # request will not use is exactly the lie this gate exists to prevent.
        org = create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                    ai_access_token: 'broken-token')
        active_credential_for('openai')
        expect(org.has_valid_ai_configuration?('openai')).to be(false)
      end
    end

    # The gate for a feature that CANNOT follow the org's choice. R3 deleted the S4
    # pair (ai_available_pinned? / ai_pinned_elsewhere?) that used to answer this in
    # two booleans; the SAME four cases are now one answer with a reason, and every
    # example below is the pair's example rewritten against it — the two predicates'
    # difference survives as the difference between :pinned_elsewhere and
    # :no_credential.
    describe '#ai_available_for? on the pinned feature' do
      let(:pinned) { ::AiCredential::PROVIDER_OPENAI }

      # THE regression this was written for: a usable OpenAI credential exists, but
      # the org routes elsewhere. ai_available?('openai') — still the low-level API —
      # says yes, and acting on that would spend the org's data at a provider its
      # admin did not choose.
      it 'refuses an org routing elsewhere even with a usable credential for the pinned provider' do
        org = create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                                    ai_access_token: 'sk-mistral-own-token-1234567890',
                                    ai_api_base: 'https://api.mistral.ai/v1',
                                    preferred_chat_model: 'mistral-small-latest')
        create(:ai_credential, :active, provider: 'openai')

        expect(org.ai_available?(pinned)).to be(true)
        availability = org.ai_available_for?(:customer_description)
        expect(availability).not_to be_available
        expect(availability.reason).to eq(:pinned_elsewhere)
        expect(availability.required_provider).to eq(pinned)
      end

      it 'allows an org that routes to the pinned provider and can use it' do
        org = create(:organisation, ai_enabled: true, ai_provider: pinned,
                                    ai_access_token: 'sk-org-own-1234567890abcdef')

        expect(org.ai_available_for?(:customer_description)).to be_available
      end

      # "Cannot use" and "pinned elsewhere" stay different answers, and the split is
      # what lets surfaces explain the absence correctly: right provider but no
      # credential is NOT a pinning problem, so the provider hint must stay silent.
      it 'separates "cannot use" from "pinned elsewhere" when the credential is missing' do
        allow(AiCredential).to receive(:active_for_provider).and_return(nil)
        org = create(:organisation, ai_enabled: true, ai_provider: pinned, ai_access_token: nil)

        availability = org.ai_available_for?(:customer_description)
        expect(availability).not_to be_available
        expect(availability.reason).to eq(:no_credential)
      end

      it 'names the missing opt-in, not the pin — that org has a different problem' do
        org = create(:organisation, :ai_disabled, ai_provider: 'openai_compatible')

        availability = org.ai_available_for?(:customer_description)
        expect(availability).not_to be_available
        expect(availability.reason).to eq(:ai_disabled)
      end
    end

    # The gate half of S1b/S1c: surfaces whose routing follows Factory.for_chat
    # must ask about the org's OWN chat provider. Pinned separately from
    # ai_available?(provider) because that one stays in use for the still-pinned
    # paths (P3/P4/P5) and must NOT start following the org choice.
    #
    # R2 removed the ai_available_for_chat? facade these examples were written
    # against; they now ask the registry directly. THE REGRESSION IS UNCHANGED —
    # only its spelling is. :chat is the honest key here because these examples are
    # about the unpinned chat LANE itself, not about one surface; every unpinned
    # chat feature answers identically (pinned by the equivalence matrix in
    # spec/models/organisation_ai_availability_spec.rb).
    describe '#ai_available_for?(:chat) — the unpinned chat lane (was #ai_available_for_chat?)' do
      it 'follows the org choice — true on Mistral even with no OpenAI config at all' do
        allow(AiCredential).to receive(:active_for_provider).and_return(nil)
        org = create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                                    ai_access_token: 'sk-mistral-own-token-1234567890',
                                    ai_api_base: 'https://api.mistral.ai/v1',
                                    preferred_chat_model: 'mistral-small-latest')

        expect(org.ai_available_for?(:chat)).to be_available
        # The very state that produced the 403 before S1c.
        expect(org.ai_available?('openai')).to be(false)
      end

      it 'resolves the provider through the SAME derivation the factory routes on' do
        org = create(:organisation, ai_enabled: true, ai_provider: 'anthropic',
                                    ai_access_token: "sk-ant-#{'a' * 95}")
        expect(org.chat_provider_name).to eq(Lalabase::Llm::Factory.chat_provider_name(org))
        expect(org.chat_provider_name).to eq('anthropic')
      end

      it 'defaults an org without an own choice to openai (unchanged behaviour)' do
        org = create(:organisation, ai_enabled: true, ai_provider: nil,
                                    ai_access_token: 'sk-org-own-1234567890abcdef')
        expect(org.chat_provider_name).to eq('openai')
        expect(org.ai_available_for?(:chat)).to be_available
      end

      it 'stays false without the opt-in, however well configured' do
        org = create(:organisation, :ai_disabled, ai_provider: 'openai_compatible',
                                                  ai_access_token: 'sk-mistral-own-token-1234567890',
                                                  ai_api_base: 'https://api.mistral.ai/v1',
                                                  preferred_chat_model: 'mistral-small-latest')
        expect(org.ai_available_for?(:chat)).not_to be_available
      end
    end

    # KI-Pakete P3 REMOVED #ai_configured_for_chat? along with its examples. The
    # predicate answered the CONFIGURATION half for a caller that had already
    # decided the opt-in — a real need, but it derived the org's OWN chat rung,
    # and its only callers (TicketSummaryService and the three summary entries on
    # the ticket page) route on the UTILITY rung. With a package whose rungs sit
    # on different credentials it therefore answered about a credential the
    # request never touches.
    #
    # The two states it protected are still kept apart, one layer up:
    # TicketSummaryService#unavailable_status maps the registry reason
    # (:ai_disabled keeps its own surface, everything else is "not configured").
    # Regression pair: "the gate follows the rung the summary routes on" in
    # spec/services/ticket_summary_service_spec.rb and its rendered twin in
    # spec/requests/organisations/ai_surface_gating_spec.rb.

    # S2: Organisation#ai_client / #ai_client_with_usage_tracking were removed — the
    # GDPR opt-in gate now lives ONLY in Lalabase::Llm::Factory (see factory_spec's
    # "GDPR AI opt-in gate", which pins the same fail-closed contract on every entry).
  end

  describe 'embedding BYOK credentials' do
    describe '#has_own_embedding_credentials?' do
      it 'is true when a token is present and the provider matches' do
        org = build(:organisation, embedding_provider: 'openai_compatible',
                                   embedding_access_token: 'sk-embed',
                                   embedding_api_base: 'https://x/v1', embedding_model: 'm-1536')
        expect(org.has_own_embedding_credentials?('openai_compatible')).to be(true)
      end

      it 'is true when a token is present and embedding_provider is blank (defaults to openai)' do
        org = build(:organisation, embedding_provider: nil, embedding_access_token: 'sk-embed')
        expect(org.has_own_embedding_credentials?('openai')).to be(true)
      end

      it 'is false when no token is present' do
        org = build(:organisation, embedding_provider: 'openai', embedding_access_token: nil)
        expect(org.has_own_embedding_credentials?('openai')).to be(false)
      end

      it 'is false when the requested provider does not match the configured one' do
        org = build(:organisation, embedding_provider: 'openai_compatible',
                                   embedding_access_token: 'sk-embed',
                                   embedding_api_base: 'https://x/v1', embedding_model: 'm-1536')
        expect(org.has_own_embedding_credentials?('openai')).to be(false)
      end

      it 'is independent of the chat ai_access_token' do
        org = build(:organisation, ai_access_token: 'sk-chat', embedding_access_token: nil)
        expect(org.has_own_embedding_credentials?('openai')).to be(false)
      end
    end

    describe 'validations' do
      it 'rejects an unsupported embedding_provider' do
        org = build(:organisation, embedding_provider: 'cohere')
        expect(org).not_to be_valid
        expect(org.errors[:embedding_provider]).to be_present
      end

      it 'accepts every embedding-capable implemented provider (derived, not hardcoded)' do
        AiCredential.embedding_capable_providers.each do |provider|
          org = build(:organisation, embedding_provider: provider)
          expect(org).to be_valid, "expected embedding_provider=#{provider} to be valid"
        end
      end

      it 'includes google since the Vertex slice but never anthropic (no embedding capability)' do
        expect(AiCredential.embedding_capable_providers).to include('google')
        expect(AiCredential.embedding_capable_providers).not_to include('anthropic')
        expect(build(:organisation, embedding_provider: 'anthropic')).not_to be_valid
      end

      it 'allows a blank embedding_provider (falls back to system)' do
        expect(build(:organisation, embedding_provider: nil)).to be_valid
      end

      it 'requires api_base and model for a full openai_compatible BYOK setup (own token)' do
        org = build(:organisation, embedding_provider: 'openai_compatible',
                                   embedding_access_token: 'sk-embed',
                                   embedding_api_base: nil, embedding_model: nil)
        expect(org).not_to be_valid
        expect(org.errors[:embedding_api_base]).to be_present
        expect(org.errors[:embedding_model]).to be_present
      end

      it 'allows openai_compatible without api_base/model when relying on the system credential' do
        # No own token → uses the system AiCredential, which supplies uri_base + model.
        expect(build(:organisation, embedding_provider: 'openai_compatible',
                                    embedding_access_token: nil)).to be_valid
      end

      it 'does not require api_base/model for the plain openai provider' do
        expect(build(:organisation, embedding_provider: 'openai',
                                    embedding_access_token: 'sk-embed')).to be_valid
      end
    end

    describe 'encryption' do
      it 'stores embedding_access_token encrypted but reads it back in clear' do
        org = create(:organisation, embedding_provider: 'openai', embedding_access_token: 'sk-secret-embed')
        expect(org.reload.embedding_access_token).to eq('sk-secret-embed')

        raw = Organisation.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(
            ['SELECT embedding_access_token FROM organisations WHERE id = ?', org.id]
          )
        )
        expect(raw).not_to include('sk-secret-embed')
      end
    end

    describe 'cross-org isolation' do
      it 'never exposes one org embedding token through another org' do
        create(:organisation, name: 'Org A', subdomain: 'a', embedding_provider: 'openai',
                              embedding_access_token: 'sk-org-a')
        org_b = create(:organisation, name: 'Org B', subdomain: 'b')
        expect(org_b.embedding_access_token).to be_nil
      end
    end

    # Rotation/backfill via TokenReencryptable. Full row semantics are pinned
    # in project_repository_spec; HERE lives the blank-row contract, because
    # organisations is the registered table whose token columns are nullable:
    # the operator verifies the key rotation against the task's numbers, so
    # "processed" must mean "actually rewritten" — a row with no token at all
    # gets no UPDATE and no counter.
    describe '.reencrypt_tokens!' do
      it 'neither counts nor touches rows without a single present token' do
        org = create(:organisation) # both token columns nil
        before = org.reload.updated_at

        expect(described_class.reencrypt_tokens!).to eq(processed: 0, failed: 0)

        expect(org.reload.updated_at).to eq(before)
      end

      it 'rewrites and counts a row as soon as one token is present' do
        create(:organisation, embedding_provider: 'openai', embedding_access_token: 'sk-rotate-embed')

        expect(described_class.reencrypt_tokens!).to eq(processed: 1, failed: 0)
      end
    end
  end
end
