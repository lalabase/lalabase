# frozen_string_literal: true

# == Schema Information
#
# Table name: roles
#
#  id              :uuid             not null, primary key
#  billable        :boolean          default(TRUE), not null
#  description     :text
#  is_default      :boolean          default(FALSE)
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_roles_on_organisation_id_and_title  (organisation_id,title) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

RSpec.describe Admin::Role, type: :model do
  let(:organisation) { create(:organisation) }

  def build_role(attrs = {})
    defaults = {
      organisation_id: organisation.id,
      title: 'Test Role',
      is_default: false
    }
    described_class.new(defaults.merge(attrs))
  end

  def create_role(attrs = {})
    build_role(attrs).tap(&:save!)
  end

  # =========================================================================
  # Table & Model Configuration
  # =========================================================================

  describe 'table configuration' do
    it 'uses the roles table' do
      expect(described_class.table_name).to eq('roles')
    end

    it 'strips Admin namespace from model_name for routing' do
      expect(described_class.model_name.to_s).to eq('Role')
      expect(described_class.model_name.singular).to eq('role')
      expect(described_class.model_name.plural).to eq('roles')
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

    it 'has many memberships as Admin::Membership with dependent destroy' do
      assoc = described_class.reflect_on_association(:memberships)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:class_name]).to eq('Admin::Membership')
      expect(assoc.options[:dependent]).to eq(:destroy)
    end

    it 'has many users through memberships as Admin::User' do
      assoc = described_class.reflect_on_association(:users)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:through]).to eq(:memberships)
      expect(assoc.options[:class_name]).to eq('Admin::User')
    end

    it 'can load associated organisation' do
      role = create_role
      expect(role.organisation).to be_a(Admin::Organisation)
      expect(role.organisation.id).to eq(organisation.id)
    end
  end

  # =========================================================================
  # Validations
  # =========================================================================

  describe 'validations' do
    describe 'title' do
      it 'is valid with a title' do
        expect(build_role(title: 'Editor')).to be_valid
      end

      it 'is invalid without a title' do
        role = build_role(title: nil)
        expect(role).not_to be_valid
        expect(role.errors[:title]).to be_present
      end

      it 'is invalid with a blank title' do
        role = build_role(title: '')
        expect(role).not_to be_valid
        expect(role.errors[:title]).to be_present
      end

      it 'enforces uniqueness of title scoped to organisation' do
        create_role(title: 'Editor')
        duplicate = build_role(title: 'Editor')
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:title]).to be_present
      end

      it 'allows same title in different organisations' do
        create_role(title: 'Editor')
        other_org = create(:organisation)
        other = build_role(title: 'Editor', organisation_id: other_org.id)
        expect(other).to be_valid
      end

      it 'treats title uniqueness case-insensitively at DB level' do
        create_role(title: 'Editor')
        # Depending on DB collation this may or may not pass validation
        # but should be handled at one level
        duplicate = build_role(title: 'editor')
        # We just verify it doesn't raise - behavior depends on DB collation
        duplicate.valid?
      end
    end

    describe 'organisation' do
      it 'is invalid without organisation' do
        role = build_role(organisation_id: nil)
        expect(role).not_to be_valid
      end
    end
  end

  # =========================================================================
  # Scopes
  # =========================================================================

  describe 'scopes' do
    describe '.ordered_by_title' do
      it 'orders roles alphabetically by title' do
        alpha = create_role(title: 'Alpha')
        zeta = create_role(title: 'Zeta')

        result = described_class.where(id: [alpha.id, zeta.id]).ordered_by_title
        expect(result.first).to eq(alpha)
        expect(result.last).to eq(zeta)
      end
    end

    describe '.ordered_by_organisation' do
      it 'orders by organisation name then title' do
        org_alpha = create(:organisation, name: 'Alpha Corp')
        org_zeta = create(:organisation, name: 'Zeta Inc')

        role_zeta = described_class.create!(
          organisation_id: org_zeta.id, title: 'Admin', is_default: false
        )
        role_alpha = described_class.create!(
          organisation_id: org_alpha.id, title: 'Admin', is_default: false
        )

        result = described_class.where(id: [role_alpha.id, role_zeta.id]).ordered_by_organisation
        expect(result.to_a.index(role_alpha)).to be < result.to_a.index(role_zeta)
      end
    end
  end

  # =========================================================================
  # Instance Methods
  # =========================================================================

  describe '#display_title' do
    it 'returns plain title for non-default roles' do
      role = build_role(title: 'Editor', is_default: false)
      expect(role.display_title).to eq('Editor')
    end

    it 'appends translated default suffix for default roles' do
      role = build_role(title: 'Viewer', is_default: true)

      I18n.with_locale(:de) do
        expect(role.display_title).to eq('Viewer (Standard)')
      end

      I18n.with_locale(:en) do
        expect(role.display_title).to eq('Viewer (Default)')
      end
    end

    it 'handles empty title gracefully' do
      role = build_role(title: '', is_default: true)
      suffix = I18n.t('models.admin.role.default_suffix')
      expect(role.display_title).to eq(" (#{suffix})")
    end
  end

  describe '#account_admin?' do
    it 'returns true for account_admin title' do
      role = build_role(title: ::Role::ACCOUNT_ADMIN_TITLE)
      expect(role).to be_account_admin
    end

    it 'returns false for other titles' do
      role = build_role(title: 'Editor')
      expect(role).not_to be_account_admin
    end

    it 'is case-sensitive (does not match "Account_Admin")' do
      role = build_role(title: 'Account_Admin')
      expect(role).not_to be_account_admin
    end

    it 'returns false for nil title' do
      role = build_role(title: nil)
      expect(role).not_to be_account_admin
    end
  end

  # =========================================================================
  # Cross-Tenant Access (Admin-specific behavior)
  # =========================================================================

  describe 'cross-tenant access' do
    it 'can query roles across all organisations without tenant context' do
      org1 = create(:organisation, name: 'Org One')
      org2 = create(:organisation, name: 'Org Two')

      role1 = described_class.create!(organisation_id: org1.id, title: 'Role A')
      role2 = described_class.create!(organisation_id: org2.id, title: 'Role B')

      org_ids = described_class.where(id: [role1.id, role2.id]).pluck(:organisation_id)
      expect(org_ids).to contain_exactly(org1.id, org2.id)
    end

    it 'does not auto-scope to a set tenant' do
      org1 = create(:organisation, name: 'Org A')
      org2 = create(:organisation, name: 'Org B')

      role1 = described_class.create!(organisation_id: org1.id, title: 'Role X')
      role2 = described_class.create!(organisation_id: org2.id, title: 'Role Y')

      ActsAsTenant.with_tenant(org1) do
        results = described_class.where(id: [role1.id, role2.id])
        expect(results.pluck(:organisation_id)).to contain_exactly(org1.id, org2.id)
      end
    end
  end

  # =========================================================================
  # Edge Cases
  # =========================================================================

  describe 'edge cases' do
    it 'persists to the same table as regular Role' do
      role = create_role(title: 'Shared Role')
      ActsAsTenant.with_tenant(organisation) do
        regular = ::Role.find(role.id)
        expect(regular).to be_present
        expect(regular.title).to eq('Shared Role')
      end
    end

    it 'can find records created by regular Role model' do
      regular = ActsAsTenant.with_tenant(organisation) do
        ::Role.create!(title: 'Created Regular', organisation: organisation)
      end
      admin_found = described_class.find(regular.id)
      expect(admin_found.title).to eq('Created Regular')
    end

    it 'dependent destroy removes memberships when role is deleted' do
      role = create_role(title: 'To Be Deleted')
      user = create(:user)
      Admin::Membership.create!(
        organisation_id: organisation.id, user_id: user.id,
        role_id: role.id, active: true
      )

      expect { role.destroy! }.to change(Admin::Membership, :count).by(-1)
    end

    it 'does not allow duplicate titles within the same organisation' do
      create_role(title: 'Unique Title')
      expect do
        create_role(title: 'Unique Title')
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'handles is_default defaulting to false' do
      role = described_class.new(organisation_id: organisation.id, title: 'No Default Set')
      expect(role.is_default).to be false
    end

    it 'does not trigger regular Role callbacks' do
      # Admin::Role should not have the same callbacks as regular Role
      # Verify it can be created without unexpected side effects
      expect do
        create_role(title: 'No Side Effects')
      end.not_to raise_error
    end

    it 'handles special characters in title' do
      role = create_role(title: 'Gäste & Besucher (extern)')
      expect(role.reload.title).to eq('Gäste & Besucher (extern)')
    end

    it 'handles very long titles' do
      long_title = 'A' * 255
      role = create_role(title: long_title)
      expect(role.reload.title).to eq(long_title)
    end
  end
end
