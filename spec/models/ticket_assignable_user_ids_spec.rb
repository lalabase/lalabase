# frozen_string_literal: true

require 'rails_helper'

# R5 regression guard (single source): assignees must have access to the ticket's project,
# not merely belong to the organisation. Ticket#assignable_user_ids is used by both the web
# (Actors::SaveTicket) and API assignee write paths.
RSpec.describe Ticket, type: :model do
  describe '#assignable_user_ids' do
    let(:organisation) { create(:organisation) }
    let(:project_a) { create(:project, organisation: organisation) }
    let(:project_b) { create(:project, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project_a, organisation: organisation) }

    let(:standard_role) do
      create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
    end

    def member_in(role = standard_role)
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      user
    end

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    it 'keeps a user with access to the ticket project' do
      user = member_in
      create(:project_permission, user: user, project: project_a, tickets_access: 'read_only')

      expect(ticket.assignable_user_ids([user.id])).to include(user.id)
    end

    it 'drops a user who only belongs to the organisation (no project access)' do
      user = member_in

      expect(ticket.assignable_user_ids([user.id])).not_to include(user.id)
    end

    it 'drops a user whose access is to a different project (IDOR via tampered ids)' do
      user = member_in
      create(:project_permission, user: user, project: project_b, tickets_access: 'read_only')

      expect(ticket.assignable_user_ids([user.id])).not_to include(user.id)
    end

    it 'keeps an org admin (access to all projects)' do
      admin = member_in(create(:role, organisation: organisation, title: 'account_admin'))

      expect(ticket.assignable_user_ids([admin.id])).to include(admin.id)
    end

    it 'returns an empty array for blank input' do
      expect(ticket.assignable_user_ids([])).to eq([])
      expect(ticket.assignable_user_ids(nil)).to eq([])
    end
  end
end
