# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketPolicy, '#move?', :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }
  let(:move_role) do
    role = create(:role, title: 'Move Tickets Role', organisation: organisation)
    create(:permission, role: role, category: 'tickets', action: 'move_tickets', allowed: true)
    role
  end

  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: admin_user) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:move_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: move_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'move?' do
    it 'allows account admins to move tickets' do
      policy = described_class.new(admin_user, ticket)
      expect(policy.move?).to be true
    end

    it 'allows users with move_tickets permission to move tickets' do
      policy = described_class.new(move_user, ticket)
      expect(policy.move?).to be true
    end

    it 'denies users without move_tickets permission' do
      policy = described_class.new(standard_user, ticket)
      expect(policy.move?).to be false
    end
  end
end
