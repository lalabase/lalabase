# frozen_string_literal: true

require 'rails_helper'

# The ONE owner of "take this person off this project". The actor picks the
# mechanism; no caller and no view may pick it instead.
RSpec.describe Actors::RevokeProjectMember, type: :service do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:manager) { member_in(admin_role) }

  let(:plain_role) { create(:role, organisation: organisation, title: 'member') }
  let(:global_reader_role) do
    role = create(:role, organisation: organisation, title: 'tickets_reader')
    create(:project_read_permission, role: role, area: 'tickets')
    role
  end

  def member_in(role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  def revoke(user)
    described_class.call(project: project, user: user, current_user: manager)
  end

  def levels_of(permission)
    ProjectPermission.access_areas.map { |area| permission.public_send("#{area}_access") }.uniq
  end

  describe 'a member whose access comes only from an explicit grant' do
    let(:user) { member_in(plain_role) }
    let!(:permission) do
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    end

    it 'succeeds' do
      expect(revoke(user)).to be_success
    end

    it 'releases the grant instead of blocking, because nothing would grant access afterwards' do
      revoke(user)
      expect(ProjectPermission.find_by(id: permission.id)).to be_nil
    end

    it 'leaves the person without access to the project' do
      revoke(user)
      expect(AccessCheck::ProjectAccessService.new(user.reload, project).can?(:read, :tickets)).to be(false)
    end

    it 'takes the person off the resolved roster' do
      revoke(user)
      expect(roster_user_ids).not_to include(user.id)
    end
  end

  describe 'a member whose role would still grant access after the explicit grant is gone' do
    let(:user) { member_in(global_reader_role) }
    let!(:permission) do
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    end

    it 'succeeds' do
      expect(revoke(user)).to be_success
    end

    it 'keeps the row and blocks every area instead of deleting it' do
      revoke(user)
      expect(ProjectPermission.find_by(id: permission.id)).to be_present
      expect(levels_of(permission.reload)).to eq(['no_access'])
    end

    it 'actually cuts off the role right (this is the whole point)' do
      revoke(user)
      expect(AccessCheck::ProjectAccessService.new(user.reload, project).can?(:read, :tickets)).to be(false)
    end

    it 'takes the person off the resolved roster' do
      revoke(user)
      expect(roster_user_ids).not_to include(user.id)
    end
  end

  describe 'a member who is on the project through a role right alone' do
    let(:user) { member_in(global_reader_role) }

    it 'writes a blocking grant even though there was no row before' do
      expect { revoke(user) }.to change { ProjectPermission.where(project: project, user: user).count }.by(1)
      expect(levels_of(ProjectPermission.find_by(project: project, user: user))).to eq(['no_access'])
    end

    it 'cuts off the role right' do
      revoke(user)
      expect(AccessCheck::ProjectAccessService.new(user.reload, project).can?(:read, :tickets)).to be(false)
    end
  end

  describe 'a member who was blocked, released, and is blocked again' do
    let(:user) { member_in(global_reader_role) }

    # The unique index on (user_id, project_id) means the second block has to
    # revive the archived row, not insert a second one.
    it 'revives the archived row instead of colliding with the unique index' do
      revoke(user)
      permission = ProjectPermission.find_by(project: project, user: user)
      permission.update!(deleted_at: Time.current)

      expect { revoke(user) }.not_to raise_error
      expect(ProjectPermission.unscoped.where(project: project, user: user).count).to eq(1)
      expect(levels_of(ProjectPermission.find_by(project: project, user: user))).to eq(['no_access'])
    end
  end

  describe 'an account admin' do
    let(:user) { member_in(admin_role) }

    it 'fails, because an admin role cannot be blocked per project' do
      result = revoke(user)

      expect(result).not_to be_success
      expect(result.code).to eq(:admin_cannot_be_revoked)
    end

    it 'writes nothing' do
      expect { revoke(user) }.not_to change(ProjectPermission, :count)
    end
  end

  describe 'a user who has no access to the project at all' do
    let(:user) { member_in(plain_role) }

    it 'fails instead of writing a pointless blocking row' do
      result = revoke(user)

      expect(result).not_to be_success
      expect(result.code).to eq(:not_a_member)
    end

    it 'writes nothing' do
      expect { revoke(user) }.not_to change(ProjectPermission, :count)
    end
  end

  # This actor deliberately leaves subscriptions alone.
  #
  # It used to delete the project subscription, because FanoutService merged subscribers
  # without re-checking rights. It checks now, so a surviving row has no effect, and
  # keeping it is what makes a removal reversible: a subscription the person had is
  # indistinguishable from one they had muted on purpose once it is deleted, and coming
  # back to the project has to restore both.
  #
  # That the row stops DELIVERING is the gate's job and is pinned in
  # spec/services/notifications/fanout_service_access_gate_spec.rb. Do not read the
  # examples here as proof that nothing arrives; they only prove nothing was destroyed.
  describe 'project notifications' do
    def subscribed?(user)
      NotificationSubscription.exists?(user: user, subscribable: project)
    end

    it 'does not subscribe a role-based member that it blocks' do
      user = member_in(global_reader_role)

      revoke(user)

      expect(subscribed?(user)).to be(false)
    end

    it 'keeps the subscription of a member it blocks, so the return needs no repair' do
      user = member_in(global_reader_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
      NotificationSubscription.system_subscribe(user: user, item: project)

      revoke(user)

      expect(subscribed?(user)).to be(true)
    end

    it 'keeps the subscription of a member it releases, so the return needs no repair' do
      user = member_in(plain_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
      NotificationSubscription.system_subscribe(user: user, item: project)

      revoke(user)

      expect(subscribed?(user)).to be(true)
    end

    it 'takes the access away all the same' do
      user = member_in(plain_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
      NotificationSubscription.system_subscribe(user: user, item: project)

      revoke(user)
      user.instance_variable_set(:@active_member_cache, nil)

      expect(AccessCheck::ProjectAccessService.can_access_project?(user, project)).to be(false)
    end

    it 'leaves the subscriptions of everyone else alone' do
      bystander = member_in(plain_role)
      create(:project_permission, user: bystander, project: project, tickets_access: 'read_write')
      NotificationSubscription.system_subscribe(user: bystander, item: project)

      revoke(member_in(global_reader_role))

      expect(subscribed?(bystander)).to be(true)
    end
  end

  describe 'activity trail' do
    let(:user) { member_in(global_reader_role) }
    let!(:permission) do
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    end

    it 'records the removal on the project even when the mechanism was a block' do
      expect { revoke(user) }
        .to change { Activity.where(action: 'member_removed', trackable: project).count }.by(1)
    end
  end

  def roster_user_ids
    AccessCheck::ProjectTeamMembers
      .new(project: project.reload, current_user: manager)
      .with_access
      .map { |member| member.user.id }
  end
end
