# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OrganisationPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }

  let(:admin_role) do
    create(:role, title: 'account_admin', organisation: organisation)
  end

  let(:standard_role) do
    create(:role, title: 'Standard User', organisation: organisation, is_default: true)
  end

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:inactive_member) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: false)
    user
  end

  let(:non_member) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # =========================================================================
  # index? — always true for authenticated users
  # =========================================================================
  describe '#index?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation)).to permit_action(:index)
    end

    it 'permits for standard member' do
      expect(described_class.new(standard_user, organisation)).to permit_action(:index)
    end

    it 'permits for non-member' do
      expect(described_class.new(non_member, organisation)).to permit_action(:index)
    end
  end

  # =========================================================================
  # show? — requires active membership
  # =========================================================================
  describe '#show?' do
    it 'permits for active member' do
      expect(described_class.new(standard_user, organisation)).to permit_action(:show)
    end

    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation)).to permit_action(:show)
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, organisation)).not_to permit_action(:show)
    end

    it 'denies for inactive member' do
      expect(described_class.new(inactive_member, organisation)).not_to permit_action(:show)
    end
  end

  # =========================================================================
  # create? — always true for authenticated users
  # =========================================================================
  describe '#create?' do
    it 'permits for any authenticated user' do
      expect(described_class.new(non_member, Organisation.new)).to permit_action(:create)
    end
  end

  # =========================================================================
  # new? — delegates to create?
  # =========================================================================
  describe '#new?' do
    it 'permits for any authenticated user' do
      expect(described_class.new(non_member, Organisation.new)).to permit_action(:new)
    end
  end

  # =========================================================================
  # update? — requires admin
  # =========================================================================
  describe '#update?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation)).to permit_action(:update)
    end

    it 'denies for standard member' do
      expect(described_class.new(standard_user, organisation)).not_to permit_action(:update)
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, organisation)).not_to permit_action(:update)
    end

    it 'denies for inactive member' do
      expect(described_class.new(inactive_member, organisation)).not_to permit_action(:update)
    end
  end

  # =========================================================================
  # edit? — delegates to update?
  # =========================================================================
  describe '#edit?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation)).to permit_action(:edit)
    end

    it 'denies for standard member' do
      expect(described_class.new(standard_user, organisation)).not_to permit_action(:edit)
    end
  end

  # =========================================================================
  # destroy? — requires admin
  # =========================================================================
  describe '#destroy?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation)).to permit_action(:destroy)
    end

    it 'denies for standard member' do
      expect(described_class.new(standard_user, organisation)).not_to permit_action(:destroy)
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, organisation)).not_to permit_action(:destroy)
    end

    it 'denies for inactive member' do
      expect(described_class.new(inactive_member, organisation)).not_to permit_action(:destroy)
    end
  end

  # =========================================================================
  # admin? — custom action, requires admin
  # =========================================================================
  describe '#admin?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation).admin?).to be true
    end

    it 'denies for standard member' do
      expect(described_class.new(standard_user, organisation).admin?).to be false
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, organisation).admin?).to be false
    end
  end

  # =========================================================================
  # select? — always true
  # =========================================================================
  describe '#select?' do
    it 'permits for any authenticated user' do
      expect(described_class.new(non_member, organisation).select?).to be true
    end
  end

  # =========================================================================
  # set? — requires active membership
  # =========================================================================
  describe '#set?' do
    it 'permits for active member' do
      expect(described_class.new(standard_user, organisation).set?).to be true
    end

    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation).set?).to be true
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, organisation).set?).to be false
    end

    it 'denies for inactive member' do
      expect(described_class.new(inactive_member, organisation).set?).to be false
    end
  end

  # =========================================================================
  # Scope
  # =========================================================================
  describe OrganisationPolicy::Scope do
    let(:other_org) { create(:organisation) }

    before do
      # Ensure users are created (trigger lets)
      admin_user
      standard_user
    end

    it 'returns organisations the user is a member of' do
      result = described_class.new(standard_user, Organisation).resolve
      expect(result).to include(organisation)
    end

    it 'excludes organisations the user is NOT a member of' do
      result = described_class.new(standard_user, Organisation).resolve
      expect(result).not_to include(other_org)
    end

    it 'returns multiple organisations if user is member of several' do
      create(:membership, user: standard_user, organisation: other_org, role: create(:role, organisation: other_org), active: true)
      result = described_class.new(standard_user, Organisation).resolve
      expect(result).to include(organisation, other_org)
    end

    it 'excludes organisations where membership is inactive' do
      create(:membership, user: non_member, organisation: other_org, role: create(:role, organisation: other_org), active: false)
      result = described_class.new(non_member, Organisation).resolve
      expect(result).not_to include(other_org)
    end

    it 'returns empty for user with no memberships' do
      result = described_class.new(non_member, Organisation).resolve
      expect(result).to be_empty
    end
  end

  # =========================================================================
  # Edge case: nil user
  # =========================================================================
  describe 'with nil user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect do
        described_class.new(nil, organisation)
      end.to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
end
