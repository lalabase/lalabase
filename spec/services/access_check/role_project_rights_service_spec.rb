# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccessCheck::RoleProjectRightsService, type: :service do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # --- Roles ---
  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:admin_role, organisation: organisation)
    end
  end

  let(:regular_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, organisation: organisation, title: 'regular_user')
    end
  end

  let(:role_with_read_tickets) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: 'tickets_reader')
      create(:project_read_permission, role: role, area: 'tickets')
      role
    end
  end

  let(:role_with_write_tickets) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: 'tickets_writer')
      create(:project_write_permission, role: role, area: 'tickets')
      role
    end
  end

  let(:role_with_read_and_write_tickets) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: 'tickets_rw')
      create(:project_read_permission, role: role, area: 'tickets')
      create(:project_write_permission, role: role, area: 'tickets')
      role
    end
  end

  let(:role_with_multiple_read_areas) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: 'multi_reader')
      create(:project_read_permission, role: role, area: 'tickets')
      create(:project_read_permission, role: role, area: 'documents')
      role
    end
  end

  let(:role_with_disabled_permission) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: 'disabled_perm')
      create(:project_read_permission, role: role, area: 'tickets', allowed: false)
      role
    end
  end

  # --- Users ---
  let(:admin_user) { create(:user) }
  let(:regular_user) { create(:user) }
  let(:tickets_reader) { create(:user) }
  let(:tickets_writer) { create(:user) }
  let(:tickets_rw_user) { create(:user) }
  let(:multi_reader) { create(:user) }
  let(:disabled_perm_user) { create(:user) }
  let(:user_without_membership) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin_user, organisation: organisation, role: admin_role)
      create(:membership, user: regular_user, organisation: organisation, role: regular_role)
      create(:membership, user: tickets_reader, organisation: organisation, role: role_with_read_tickets)
      create(:membership, user: tickets_writer, organisation: organisation, role: role_with_write_tickets)
      create(:membership, user: tickets_rw_user, organisation: organisation, role: role_with_read_and_write_tickets)
      create(:membership, user: multi_reader, organisation: organisation, role: role_with_multiple_read_areas)
      create(:membership, user: disabled_perm_user, organisation: organisation, role: role_with_disabled_permission)
    end
  end

  # =========================================================================
  # Instance Methods
  # =========================================================================

  describe 'instance methods' do
    subject(:service) { described_class.new(user, organisation) }

    # -----------------------------------------------------------------------
    # #has_global_read_access?
    # -----------------------------------------------------------------------
    describe '#has_global_read_access?' do
      context 'when user is account admin' do
        let(:user) { admin_user }

        it 'returns true without area' do
          expect(service.has_global_read_access?).to be true
        end

        it 'returns true for any area' do
          ProjectPermission.access_areas.each do |area|
            expect(service.has_global_read_access?(area)).to be(true), "Expected true for area #{area}"
          end
        end
      end

      context 'when user has read permission for specific area' do
        let(:user) { tickets_reader }

        it 'returns true for that area' do
          expect(service.has_global_read_access?(:tickets)).to be true
        end

        it 'returns false for a different area' do
          expect(service.has_global_read_access?(:documents)).to be false
        end

        it 'returns true without area (any area check)' do
          expect(service.has_global_read_access?).to be true
        end
      end

      context 'when user has no permissions' do
        let(:user) { regular_user }

        it 'returns false for any specific area' do
          expect(service.has_global_read_access?(:tickets)).to be false
        end

        it 'returns false without area' do
          expect(service.has_global_read_access?).to be false
        end
      end

      context 'when user has no membership in organisation' do
        let(:user) { user_without_membership }

        it 'returns false for any area' do
          expect(service.has_global_read_access?(:tickets)).to be false
        end

        it 'returns false without area' do
          expect(service.has_global_read_access?).to be false
        end
      end

      context 'when permission exists but is not allowed' do
        let(:user) { disabled_perm_user }

        it 'returns false for that area' do
          expect(service.has_global_read_access?(:tickets)).to be false
        end
      end

      context 'when user has read permissions for multiple areas' do
        let(:user) { multi_reader }

        it 'returns true for each permitted area' do
          expect(service.has_global_read_access?(:tickets)).to be true
          expect(service.has_global_read_access?(:documents)).to be true
        end

        it 'returns false for non-permitted areas' do
          expect(service.has_global_read_access?(:chats)).to be false
          expect(service.has_global_read_access?(:notes)).to be false
        end

        it 'returns true without area (any area check)' do
          expect(service.has_global_read_access?).to be true
        end
      end

      context 'with invalid area name' do
        let(:user) { admin_user }

        it 'returns true for admin regardless of area name' do
          expect(service.has_global_read_access?(:nonexistent)).to be true
        end
      end

      context 'with invalid area name for non-admin' do
        let(:user) { tickets_reader }

        it 'returns false for non-existent area' do
          expect(service.has_global_read_access?(:nonexistent)).to be false
        end
      end
    end

    # -----------------------------------------------------------------------
    # #has_global_write_access?
    # -----------------------------------------------------------------------
    describe '#has_global_write_access?' do
      context 'when user is account admin' do
        let(:user) { admin_user }

        it 'returns true without area' do
          expect(service.has_global_write_access?).to be true
        end

        it 'returns true for any area' do
          ProjectPermission.access_areas.each do |area|
            expect(service.has_global_write_access?(area)).to be(true), "Expected true for area #{area}"
          end
        end
      end

      context 'when user has write permission for specific area' do
        let(:user) { tickets_writer }

        it 'returns true for that area' do
          expect(service.has_global_write_access?(:tickets)).to be true
        end

        it 'returns false for a different area' do
          expect(service.has_global_write_access?(:documents)).to be false
        end

        it 'returns true without area (any area check)' do
          expect(service.has_global_write_access?).to be true
        end
      end

      context 'when user has only read permission (no write)' do
        let(:user) { tickets_reader }

        it 'returns false for that area' do
          expect(service.has_global_write_access?(:tickets)).to be false
        end

        it 'returns false without area' do
          expect(service.has_global_write_access?).to be false
        end
      end

      context 'when user has no permissions' do
        let(:user) { regular_user }

        it 'returns false' do
          expect(service.has_global_write_access?(:tickets)).to be false
        end
      end

      context 'when user has no membership in organisation' do
        let(:user) { user_without_membership }

        it 'returns false' do
          expect(service.has_global_write_access?(:tickets)).to be false
        end
      end
    end

    # -----------------------------------------------------------------------
    # #effective_role_access_level
    # -----------------------------------------------------------------------
    describe '#effective_role_access_level' do
      context 'when user has write access' do
        let(:user) { tickets_writer }

        it 'returns read_write' do
          expect(service.effective_role_access_level(:tickets)).to eq('read_write')
        end
      end

      context 'when user has both read and write access' do
        let(:user) { tickets_rw_user }

        it 'returns read_write' do
          expect(service.effective_role_access_level(:tickets)).to eq('read_write')
        end
      end

      context 'when user has only read access' do
        let(:user) { tickets_reader }

        it 'returns read_only' do
          expect(service.effective_role_access_level(:tickets)).to eq('read_only')
        end
      end

      context 'when user has no access' do
        let(:user) { regular_user }

        it 'returns no_access' do
          expect(service.effective_role_access_level(:tickets)).to eq('no_access')
        end
      end

      context 'when user is account admin' do
        let(:user) { admin_user }

        it 'returns read_write for any area' do
          ProjectPermission.access_areas.each do |area|
            expect(service.effective_role_access_level(area)).to eq('read_write'),
                                                                 "Expected read_write for area #{area}"
          end
        end
      end

      context 'when user has permission in one area but checked for another' do
        let(:user) { tickets_reader }

        it 'returns no_access for unrelated area' do
          expect(service.effective_role_access_level(:documents)).to eq('no_access')
        end
      end

      context 'when user has no membership' do
        let(:user) { user_without_membership }

        it 'returns no_access' do
          expect(service.effective_role_access_level(:tickets)).to eq('no_access')
        end
      end
    end

    # -----------------------------------------------------------------------
    # #can_read?
    # -----------------------------------------------------------------------
    describe '#can_read?' do
      context 'when user has read permission' do
        let(:user) { tickets_reader }

        it 'returns true' do
          expect(service.can_read?(:tickets)).to be true
        end
      end

      context 'when user has write permission but no explicit read' do
        let(:user) { tickets_writer }

        it 'returns true (write implies read)' do
          expect(service.can_read?(:tickets)).to be true
        end
      end

      context 'when user has both read and write' do
        let(:user) { tickets_rw_user }

        it 'returns true' do
          expect(service.can_read?(:tickets)).to be true
        end
      end

      context 'when user has no permissions' do
        let(:user) { regular_user }

        it 'returns false' do
          expect(service.can_read?(:tickets)).to be false
        end
      end

      context 'when user is admin' do
        let(:user) { admin_user }

        it 'returns true' do
          expect(service.can_read?(:tickets)).to be true
        end
      end

      context 'when permission exists but is disabled' do
        let(:user) { disabled_perm_user }

        it 'returns false' do
          expect(service.can_read?(:tickets)).to be false
        end
      end
    end

    # -----------------------------------------------------------------------
    # #can_write?
    # -----------------------------------------------------------------------
    describe '#can_write?' do
      context 'when user has write permission' do
        let(:user) { tickets_writer }

        it 'returns true' do
          expect(service.can_write?(:tickets)).to be true
        end
      end

      context 'when user has only read permission' do
        let(:user) { tickets_reader }

        it 'returns false' do
          expect(service.can_write?(:tickets)).to be false
        end
      end

      context 'when user has no permissions' do
        let(:user) { regular_user }

        it 'returns false' do
          expect(service.can_write?(:tickets)).to be false
        end
      end

      context 'when user is admin' do
        let(:user) { admin_user }

        it 'returns true' do
          expect(service.can_write?(:tickets)).to be true
        end
      end

      context 'when user has no membership' do
        let(:user) { user_without_membership }

        it 'returns false' do
          expect(service.can_write?(:tickets)).to be false
        end
      end
    end
  end

  # =========================================================================
  # Class Methods
  # =========================================================================

  describe 'class methods' do
    describe '.access_areas' do
      it 'delegates to ProjectPermission' do
        expect(described_class.access_areas).to eq(ProjectPermission.access_areas)
      end

      it 'returns all expected areas' do
        # :meetings was added to the area canon in Gespräche Slice 1a; this pin was
        # not carried along then (pre-existing drift), fixed here alongside Slice 6.
        expect(described_class.access_areas).to contain_exactly(:tickets, :notes, :chats, :documents, :members,
                                                                :documentation, :meetings)
      end
    end

    describe '.has_global_read_access?' do
      it 'returns true for admin' do
        expect(described_class.has_global_read_access?(admin_user, organisation, :tickets)).to be true
      end

      it 'returns true for user with read permission' do
        expect(described_class.has_global_read_access?(tickets_reader, organisation, :tickets)).to be true
      end

      it 'returns false for user without permission' do
        expect(described_class.has_global_read_access?(regular_user, organisation, :tickets)).to be false
      end

      it 'returns false for user without membership' do
        expect(described_class.has_global_read_access?(user_without_membership, organisation, :tickets)).to be false
      end

      context 'without area argument' do
        it 'returns true if user has any read permission' do
          expect(described_class.has_global_read_access?(tickets_reader, organisation)).to be true
        end

        it 'returns false if user has no read permissions' do
          expect(described_class.has_global_read_access?(regular_user, organisation)).to be false
        end
      end
    end

    describe '.has_global_write_access?' do
      it 'returns true for admin' do
        expect(described_class.has_global_write_access?(admin_user, organisation, :tickets)).to be true
      end

      it 'returns true for user with write permission' do
        expect(described_class.has_global_write_access?(tickets_writer, organisation, :tickets)).to be true
      end

      it 'returns false for user with only read permission' do
        expect(described_class.has_global_write_access?(tickets_reader, organisation, :tickets)).to be false
      end

      it 'returns false for user without membership' do
        expect(described_class.has_global_write_access?(user_without_membership, organisation, :tickets)).to be false
      end

      context 'without area argument' do
        it 'returns true if user has any write permission' do
          expect(described_class.has_global_write_access?(tickets_writer, organisation)).to be true
        end

        it 'returns false if user has no write permissions' do
          expect(described_class.has_global_write_access?(regular_user, organisation)).to be false
        end
      end
    end

    describe '.effective_role_access_level' do
      it 'returns read_write for admin' do
        expect(described_class.effective_role_access_level(admin_user, organisation, :tickets)).to eq('read_write')
      end

      it 'returns read_write for user with write permission' do
        expect(described_class.effective_role_access_level(tickets_writer, organisation, :tickets)).to eq('read_write')
      end

      it 'returns read_only for user with read permission' do
        expect(described_class.effective_role_access_level(tickets_reader, organisation, :tickets)).to eq('read_only')
      end

      it 'returns no_access for user without permissions' do
        expect(described_class.effective_role_access_level(regular_user, organisation, :tickets)).to eq('no_access')
      end
    end
  end

  # =========================================================================
  # Cross-Tenant Isolation
  # =========================================================================

  describe 'cross-tenant isolation' do
    let(:other_organisation) { create(:organisation) }
    let(:user_in_both) { create(:user) }

    let(:role_in_other_org) do
      ActsAsTenant.with_tenant(other_organisation) do
        role = create(:role, organisation: other_organisation, title: 'other_reader')
        create(:project_read_permission, role: role, area: 'tickets')
        role
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user_in_both, organisation: organisation, role: regular_role)
      end
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: user_in_both, organisation: other_organisation, role: role_in_other_org)
      end
    end

    it 'does not leak permissions across organisations' do
      # Org1: user has no read permission for tickets
      ActsAsTenant.with_tenant(organisation) do
        service_org1 = described_class.new(user_in_both, organisation)
        expect(service_org1.has_global_read_access?(:tickets)).to be false
      end

      # Org2: user has read permission for tickets
      ActsAsTenant.with_tenant(other_organisation) do
        service_org2 = described_class.new(user_in_both, other_organisation)
        expect(service_org2.has_global_read_access?(:tickets)).to be true
      end
    end

    it 'returns different access levels per organisation' do
      ActsAsTenant.with_tenant(organisation) do
        service_org1 = described_class.new(user_in_both, organisation)
        expect(service_org1.effective_role_access_level(:tickets)).to eq('no_access')
      end

      ActsAsTenant.with_tenant(other_organisation) do
        service_org2 = described_class.new(user_in_both, other_organisation)
        expect(service_org2.effective_role_access_level(:tickets)).to eq('read_only')
      end
    end
  end

  # =========================================================================
  # Consistency: Instance vs Class methods
  # =========================================================================

  describe 'instance/class method parity' do
    let(:user) { tickets_rw_user }

    it 'returns the same results for has_global_read_access?' do
      service = described_class.new(user, organisation)
      ProjectPermission.access_areas.each do |area|
        expect(service.has_global_read_access?(area)).to eq(
          described_class.has_global_read_access?(user, organisation, area)
        ), "Mismatch for has_global_read_access?(#{area})"
      end
    end

    it 'returns the same results for has_global_write_access?' do
      service = described_class.new(user, organisation)
      ProjectPermission.access_areas.each do |area|
        expect(service.has_global_write_access?(area)).to eq(
          described_class.has_global_write_access?(user, organisation, area)
        ), "Mismatch for has_global_write_access?(#{area})"
      end
    end

    it 'returns the same results for effective_role_access_level' do
      service = described_class.new(user, organisation)
      ProjectPermission.access_areas.each do |area|
        expect(service.effective_role_access_level(area)).to eq(
          described_class.effective_role_access_level(user, organisation, area)
        ), "Mismatch for effective_role_access_level(#{area})"
      end
    end
  end
end
