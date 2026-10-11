# frozen_string_literal: true

require 'rails_helper'

# Actors::SaveRole updates a role's own attributes AND syncs its permissions in one
# transaction. It is the write seam behind Organisations::RolesController#update and reuses
# RolePermissionSync for the permission half, so role-attribute and permission writes are
# atomic together (a failing permission rolls the role rename back).
RSpec.describe Actors::SaveRole, type: :service do
  let(:organisation) { create(:organisation) }
  let(:role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, organisation: organisation, title: 'Old Title', description: 'old')
    end
  end
  # An account admin may change any right (RolePolicy#change_permission?); the
  # limits for a role manager are pinned in
  # spec/requests/organisations/privilege_boundaries_spec.rb.
  let(:current_user) do
    create(:user).tap do |user|
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation,
                            role: create(:admin_role, organisation: organisation), active: true)
      end
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe '#call' do
    it 'updates the role attributes and syncs the permissions' do
      result = described_class.call(
        role: role,
        role_params: { title: 'New Title', description: 'new' },
        permissions: { 'accounts' => { 'manage_users' => '1' } },
        current_user: current_user
      )

      expect(result).to be_success
      expect(role.reload.title).to eq('New Title')
      expect(role.permissions.find_by(category: 'accounts', action: 'manage_users').allowed).to be true
    end

    it 'updates the role with an empty permissions hash' do
      result = described_class.call(role: role, role_params: { title: 'Renamed' }, permissions: {},
                                    current_user: current_user)

      expect(result).to be_success
      expect(role.reload.title).to eq('Renamed')
    end

    it 'rolls the role rename back when a permission is invalid (atomic)' do
      result = described_class.call(
        role: role,
        role_params: { title: 'Should Not Stick' },
        permissions: { 'accounts' => { 'bogus_action' => '1' } },
        current_user: current_user
      )

      expect(result).not_to be_success
      expect(role.reload.title).to eq('Old Title')
    end
  end
end
