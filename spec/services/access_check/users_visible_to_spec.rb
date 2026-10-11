# frozen_string_literal: true

require 'rails_helper'

# Canonical "people the user may see" source, shared by R3 (permissions add-picker),
# R4 (filter-builder user refs) and PE1 (org member list). A user sees collaborators from
# projects they can access plus org-wide staff (admins/global roles) — never regular users
# from projects they cannot access. Admins see the whole organisation.
RSpec.describe AccessCheck::ProjectAccessService do
  describe '.users_visible_to' do
    let(:organisation) { create(:organisation) }
    let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
    let(:standard_role) do
      create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
    end

    def member_in(role = standard_role)
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      user
    end

    let(:project_a) { create(:project, organisation: organisation) }
    let(:project_b) { create(:project, organisation: organisation) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    it 'returns the whole organisation for an org admin' do
      admin = member_in(admin_role)
      other = member_in

      result = described_class.users_visible_to(admin, organisation)

      expect(result).to include(admin, other)
    end

    it 'includes collaborators from an accessible project' do
      me = member_in
      colleague = member_in
      create(:project_permission, user: me, project: project_a, tickets_access: 'read_only')
      create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')

      expect(described_class.users_visible_to(me, organisation)).to include(colleague)
    end

    it 'excludes users whose only project is one the viewer cannot access' do
      me = member_in
      foreigner = member_in
      create(:project_permission, user: me, project: project_a, tickets_access: 'read_only')
      create(:project_permission, user: foreigner, project: project_b, tickets_access: 'read_only')

      expect(described_class.users_visible_to(me, organisation)).not_to include(foreigner)
    end

    it 'includes org admins so a regular member can find/contact them' do
      me = member_in
      admin = member_in(admin_role)
      create(:project_permission, user: me, project: project_a, tickets_access: 'read_only')

      expect(described_class.users_visible_to(me, organisation)).to include(admin)
    end

    it 'returns no foreign users for a member without access to any project' do
      me = member_in
      foreigner = member_in
      create(:project_permission, user: foreigner, project: project_a, tickets_access: 'read_only')

      expect(described_class.users_visible_to(me, organisation)).not_to include(foreigner)
    end
  end
end
