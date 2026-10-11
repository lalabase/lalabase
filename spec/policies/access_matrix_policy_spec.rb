# frozen_string_literal: true

require 'rails_helper'

# Locks the v1 visibility decision for the org-wide access matrix: account_admin ONLY.
# A `manage_users` grant is deliberately NOT enough — it implies no project visibility, so
# granting it would leak project existence/team. The negative case pins that so a future
# `|| has_permission?(..., 'manage_users')` cannot silently widen the gate.
RSpec.describe AccessMatrixPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def member_with(role)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  describe '#index?' do
    it 'grants an account admin' do
      admin = member_with(create(:admin_role, organisation: organisation))

      expect(described_class.new(admin, :access_matrix).index?).to be(true)
    end

    it 'denies a non-admin who only holds manage_users' do
      role = create(:role, organisation: organisation, title: 'user_manager')
      create(:permission, role: role, category: 'accounts', action: 'manage_users', allowed: true)
      manager = member_with(role)

      expect(described_class.new(manager, :access_matrix).index?).to be(false)
    end

    it 'denies a plain member' do
      member = member_with(create(:role, organisation: organisation, title: 'plain'))

      expect(described_class.new(member, :access_matrix).index?).to be(false)
    end

    it 'raises without a logged-in user (ApplicationPolicy contract)' do
      expect { described_class.new(nil, :access_matrix) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
