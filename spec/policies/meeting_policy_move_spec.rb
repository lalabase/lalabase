# frozen_string_literal: true

require 'rails_helper'

# Moving a meeting needs the role permission move_meetings (account admins
# always may) AND meetings write access in the meeting's project. Write access
# in the target project is the controller's and the actor's question.
RSpec.describe MeetingPolicy, '#move?', :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:move_role) do
    role = create(:role, title: 'Move Meetings Role', organisation: organisation)
    create(:permission, role: role, category: 'meetings', action: 'move_meetings', allowed: true)
    role
  end
  let(:plain_role) { create(:role, title: 'Plain Role', organisation: organisation) }

  def member(role, meetings_access: nil, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    create(:project_permission, user: user, project: project, meetings_access: meetings_access) if meetings_access
    user
  end

  let(:admin_user) { member(admin_role) }
  let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: admin_user) }

  before { ActsAsTenant.current_tenant = organisation }

  def move?(user)
    described_class.new(user, meeting).move?
  end

  it 'allows account admins' do
    expect(move?(admin_user)).to be true
  end

  it 'allows a user with move_meetings who may write meetings in the project' do
    expect(move?(member(move_role, meetings_access: 'read_write'))).to be true
  end

  it 'denies a user with move_meetings who may only read meetings in the project' do
    expect(move?(member(move_role, meetings_access: 'read_only'))).to be false
  end

  it 'denies a user who may write meetings but lacks move_meetings' do
    expect(move?(member(plain_role, meetings_access: 'read_write'))).to be false
  end

  it 'denies a deactivated member even with move_meetings and write access' do
    expect(move?(member(move_role, meetings_access: 'read_write', active: false))).to be false
  end

  it 'denies everyone in an archived project, account admins included' do
    project.update!(archived_at: Time.current)

    expect(move?(admin_user)).to be false
  end
end
