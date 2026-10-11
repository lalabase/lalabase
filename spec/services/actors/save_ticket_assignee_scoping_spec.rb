# frozen_string_literal: true

require 'rails_helper'

# R5 regression guard (web write path): SaveTicket must only assign users with access to the
# ticket's project. A project-foreign org member passed via assignee_ids must be dropped.
RSpec.describe Actors::SaveTicket do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }

  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  def member_in(role = standard_role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:creator) { member_in }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  it 'assigns a user with access to the project' do
    member = member_in
    create(:project_permission, user: member, project: project, tickets_access: 'read_write')

    result = described_class.new(project: project, params: { title: 'With member', assignee_ids: [member.id] }, current_user: creator).call

    expect(result.resource.reload.assignees).to include(member)
  end

  it 'does not assign a project-foreign org member (param tampering)' do
    foreigner = member_in
    create(:project_permission, user: foreigner, project: other_project, tickets_access: 'read_write')

    result = described_class.new(project: project, params: { title: 'With foreigner', assignee_ids: [foreigner.id] }, current_user: creator).call

    expect(result.resource.reload.assignees).not_to include(foreigner)
  end
end
