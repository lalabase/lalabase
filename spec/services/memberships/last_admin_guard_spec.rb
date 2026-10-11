# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Memberships::LastAdminGuard do
  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:standard_role) { create(:role, organisation: organisation, title: 'Standard') }
  let(:admin) { create(:user) }
  let!(:admin_membership) { create(:membership, organisation: organisation, user: admin, role: admin_role, active: true) }

  describe '.blocks?' do
    it 'blocks demoting the only active admin' do
      admin_membership.role = standard_role

      expect(described_class.blocks?(admin_membership)).to be(true)
    end

    it 'blocks removing the only active admin' do
      expect(described_class.blocks?(admin_membership, removing: true)).to be(true)
    end

    it 'does not block a change that keeps them an active admin' do
      expect(described_class.blocks?(admin_membership)).to be(false)
    end

    it 'does not block a change to a membership that was no active admin' do
      member = create(:membership, organisation: organisation, user: create(:user), role: standard_role, active: true)
      member.active = false

      expect(described_class.blocks?(member)).to be(false)
    end

    context 'with a second admin' do
      let(:other) { create(:user) }
      let!(:other_membership) { create(:membership, organisation: organisation, user: other, role: admin_role, active: true) }

      it 'lets the first one go' do
        expect(described_class.blocks?(admin_membership, removing: true)).to be(false)
      end

      it 'does not count the second one when their membership is inactive' do
        other_membership.update!(active: false)

        expect(described_class.blocks?(admin_membership, removing: true)).to be(true)
      end

      it 'does not count the second one when their account is deactivated' do
        other.update_columns(active: false)

        expect(described_class.blocks?(admin_membership, removing: true)).to be(true)
      end
    end
  end

  describe '.organisations_left_without_admin' do
    it 'names the organisations where the user is the last active admin' do
      expect(described_class.organisations_left_without_admin(admin)).to eq([organisation])
    end
  end
end
