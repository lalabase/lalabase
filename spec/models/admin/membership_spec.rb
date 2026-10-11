# frozen_string_literal: true

# == Schema Information
#
# Table name: memberships
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(TRUE), not null
#  role            :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  role_id         :uuid
#  user_id         :uuid             not null
#
# Indexes
#
#  index_memberships_on_organisation_id              (organisation_id)
#  index_memberships_on_role_id                      (role_id)
#  index_memberships_on_user_id                      (user_id)
#  index_memberships_on_user_id_and_organisation_id  (user_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (role_id => roles.id)
#
require 'rails_helper'

RSpec.describe Admin::Membership, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, organisation: organisation)
    end
  end

  def build_membership(attrs = {})
    defaults = {
      organisation_id: organisation.id,
      user_id: user.id,
      role_id: role.id,
      active: true
    }
    described_class.new(defaults.merge(attrs))
  end

  def create_membership(attrs = {})
    build_membership(attrs).tap(&:save!)
  end

  # =========================================================================
  # Table & Model Configuration
  # =========================================================================

  describe 'table configuration' do
    it 'uses the memberships table' do
      expect(described_class.table_name).to eq('memberships')
    end

    it 'strips Admin namespace from model_name for routing' do
      expect(described_class.model_name.to_s).to eq('Membership')
      expect(described_class.model_name.singular).to eq('membership')
      expect(described_class.model_name.plural).to eq('memberships')
    end

    it 'does not use acts_as_tenant' do
      expect(described_class).not_to respond_to(:scoped_by_tenant?)
    end
  end

  # =========================================================================
  # Associations
  # =========================================================================

  describe 'associations' do
    it 'belongs to organisation as Admin::Organisation' do
      assoc = described_class.reflect_on_association(:organisation)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:class_name]).to eq('Admin::Organisation')
    end

    it 'belongs to user as Admin::User' do
      assoc = described_class.reflect_on_association(:user)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:class_name]).to eq('Admin::User')
    end

    it 'belongs to role as Admin::Role (optional)' do
      assoc = described_class.reflect_on_association(:role)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:class_name]).to eq('Admin::Role')
      expect(assoc.options[:optional]).to be true
    end

    it 'can load associated organisation' do
      membership = create_membership
      expect(membership.organisation).to be_a(Admin::Organisation)
      expect(membership.organisation.id).to eq(organisation.id)
    end

    it 'can load associated user' do
      membership = create_membership
      expect(membership.user).to be_a(Admin::User)
      expect(membership.user.id).to eq(user.id)
    end

    it 'can load associated role' do
      membership = create_membership
      expect(membership.role).to be_a(Admin::Role)
      expect(membership.role.id).to eq(role.id)
    end
  end

  # =========================================================================
  # Validations
  # =========================================================================

  describe 'validations' do
    describe 'user_id uniqueness scoped to organisation_id' do
      it 'allows same user in different organisations' do
        other_org = create(:organisation)
        create_membership
        duplicate = build_membership(organisation_id: other_org.id)
        expect(duplicate).to be_valid
      end

      it 'rejects duplicate user in same organisation' do
        create_membership
        duplicate = build_membership
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it 'allows different users in same organisation' do
        other_user = create(:user)
        create_membership
        other = build_membership(user_id: other_user.id)
        expect(other).to be_valid
      end
    end

    describe 'active inclusion' do
      it 'is valid with active true' do
        expect(build_membership(active: true)).to be_valid
      end

      it 'is valid with active false' do
        expect(build_membership(active: false)).to be_valid
      end

      it 'is invalid with active nil' do
        membership = build_membership(active: nil)
        expect(membership).not_to be_valid
        expect(membership.errors[:active]).to be_present
      end
    end

    describe 'required associations' do
      it 'is invalid without organisation' do
        membership = build_membership(organisation_id: nil)
        expect(membership).not_to be_valid
      end

      it 'is invalid without user' do
        membership = build_membership(user_id: nil)
        expect(membership).not_to be_valid
      end

      it 'is valid without role (optional)' do
        membership = build_membership(role_id: nil)
        expect(membership).to be_valid
      end
    end
  end

  # =========================================================================
  # Scopes
  # =========================================================================

  describe 'scopes' do
    let!(:active_membership) { create_membership(active: true) }
    let!(:inactive_membership) do
      other_user = create(:user)
      create_membership(user_id: other_user.id, active: false)
    end

    describe '.active' do
      it 'returns only active memberships' do
        result = described_class.active
        expect(result).to include(active_membership)
        expect(result).not_to include(inactive_membership)
      end
    end

    describe '.inactive' do
      it 'returns only inactive memberships' do
        result = described_class.inactive
        expect(result).to include(inactive_membership)
        expect(result).not_to include(active_membership)
      end
    end

    describe '.ordered_by_organisation' do
      it 'orders memberships by organisation name ascending' do
        org_alpha = create(:organisation, name: 'Alpha Corp')
        org_zeta = create(:organisation, name: 'Zeta Inc')
        user_a = create(:user)
        user_z = create(:user)

        mem_zeta = described_class.create!(
          organisation_id: org_zeta.id, user_id: user_z.id, active: true
        )
        mem_alpha = described_class.create!(
          organisation_id: org_alpha.id, user_id: user_a.id, active: true
        )

        result = described_class.ordered_by_organisation
        alpha_idx = result.to_a.index(mem_alpha)
        zeta_idx = result.to_a.index(mem_zeta)

        expect(alpha_idx).to be < zeta_idx
      end
    end

    describe 'scope chaining' do
      it 'chains active with ordered_by_organisation' do
        result = described_class.active.ordered_by_organisation
        expect(result).to include(active_membership)
        expect(result).not_to include(inactive_membership)
      end
    end
  end

  # =========================================================================
  # Delegate Methods
  # =========================================================================

  describe '#organisation_name' do
    it 'returns the organisation name' do
      membership = create_membership
      expect(membership.organisation_name).to eq(organisation.name)
    end
  end

  describe '#user_email' do
    it 'returns the user email' do
      membership = create_membership
      expect(membership.user_email).to eq(user.email)
    end
  end

  # =========================================================================
  # Instance Methods
  # =========================================================================

  describe '#role_title' do
    context 'with a role assigned' do
      it 'returns the role title' do
        membership = create_membership
        expect(membership.role_title).to eq(role.title)
      end
    end

    context 'without a role' do
      it 'returns the i18n fallback text' do
        membership = create_membership(role_id: nil)
        expect(membership.role_title).to eq(I18n.t('models.admin.membership.no_role'))
      end
    end
  end

  describe '#status_text' do
    it 'returns translated active status for active membership' do
      membership = build_membership(active: true)
      expect(membership.status_text).to eq(I18n.t('models.admin.membership.status.active'))
    end

    it 'returns translated inactive status for inactive membership' do
      membership = build_membership(active: false)
      expect(membership.status_text).to eq(I18n.t('models.admin.membership.status.inactive'))
    end
  end

  describe '#account_admin?' do
    context 'with account_admin role' do
      let(:admin_role) do
        ActsAsTenant.with_tenant(organisation) do
          create(:admin_role, organisation: organisation)
        end
      end

      it 'returns true' do
        membership = create_membership(role_id: admin_role.id)
        expect(membership).to be_account_admin
      end
    end

    context 'with regular role' do
      it 'returns false' do
        membership = create_membership
        expect(membership).not_to be_account_admin
      end
    end

    context 'without role (nil)' do
      it 'returns false' do
        membership = create_membership(role_id: nil)
        expect(membership).not_to be_account_admin
      end
    end
  end

  # =========================================================================
  # Cross-Tenant Access (Admin-specific behavior)
  # =========================================================================

  describe 'cross-tenant access' do
    it 'can query memberships across all organisations without tenant context' do
      org1 = create(:organisation, name: 'Org One')
      org2 = create(:organisation, name: 'Org Two')
      user1 = create(:user)
      user2 = create(:user)

      described_class.create!(organisation_id: org1.id, user_id: user1.id, active: true)
      described_class.create!(organisation_id: org2.id, user_id: user2.id, active: true)

      # Without setting any tenant, should return memberships from both orgs
      org_ids = described_class.where(
        organisation_id: [org1.id, org2.id]
      ).pluck(:organisation_id)

      expect(org_ids).to contain_exactly(org1.id, org2.id)
    end

    it 'does not auto-scope to a set tenant' do
      org1 = create(:organisation, name: 'Org A')
      org2 = create(:organisation, name: 'Org B')
      user1 = create(:user)
      user2 = create(:user)

      described_class.create!(organisation_id: org1.id, user_id: user1.id, active: true)
      described_class.create!(organisation_id: org2.id, user_id: user2.id, active: true)

      # Even with tenant set, Admin model should still return all memberships
      ActsAsTenant.with_tenant(org1) do
        results = described_class.where(organisation_id: [org1.id, org2.id])
        expect(results.pluck(:organisation_id)).to contain_exactly(org1.id, org2.id)
      end
    end
  end

  # =========================================================================
  # Edge Cases
  # =========================================================================

  describe 'edge cases' do
    it 'does not trigger assign_default_role callback (unlike regular Membership)' do
      # Admin::Membership should not have the after_create callback
      # that the regular Membership model has
      membership = create_membership(role_id: nil)
      membership.reload
      expect(membership.role_id).to be_nil
    end

    it 'persists to the same table as regular Membership' do
      membership = create_membership
      regular = ::Membership.find(membership.id)
      expect(regular).to be_present
      expect(regular.user_id).to eq(membership.user_id)
    end

    it 'can be found by regular Membership model' do
      ActsAsTenant.with_tenant(organisation) do
        regular = ::Membership.create!(
          user: user,
          organisation: organisation,
          active: true
        )
        admin_found = described_class.find(regular.id)
        expect(admin_found.user_id).to eq(regular.user_id)
      end
    end
  end
end
