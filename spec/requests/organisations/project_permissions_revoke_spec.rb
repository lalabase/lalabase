# frozen_string_literal: true

require 'rails_helper'

# The Team page promises that "Entfernen" takes a person off the project. Before
# this spec existed, the button only dropped the explicit grant, so anyone whose
# ROLE carried a global project right came straight back as "via Rolle", with a
# success flash, and without a remove button for a second attempt.
RSpec.describe 'Organisations::ProjectPermissions revoke', type: :request do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:plain_role) { create(:role, organisation: organisation, title: 'member') }
  let(:global_reader_role) do
    role = create(:role, organisation: organisation, title: 'tickets_reader')
    create(:project_read_permission, role: role, area: 'tickets')
    role
  end

  def member_in(role, name:)
    user = create(:user, first_name: name, last_name: 'Testperson')
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let!(:admin) { member_in(admin_role, name: 'Ada') }

  let(:index_path) { organisation_project_project_permissions_path(organisation, project) }

  def revoke_path(user)
    revoke_organisation_project_project_permissions_path(organisation, project, user_id: user.id)
  end

  def permission_path(permission)
    organisation_project_project_permission_path(organisation, project, permission)
  end

  describe 'a member who is on the project through a global role right' do
    let!(:member) { member_in(global_reader_role, name: 'Rolf') }

    before { sign_in admin }

    it 'is listed on the team page before the removal' do
      get index_path
      expect(response.body).to include('Rolf Testperson')
    end

    it 'offers a remove button on the role-based row (no detour via "Explizit setzen")' do
      get index_path
      expect(response.body).to include(revoke_path(member))
    end

    it 'is gone from the roster after the removal' do
      delete revoke_path(member)

      roster = ActsAsTenant.with_tenant(organisation) do
        AccessCheck::ProjectTeamMembers.new(project: project.reload, current_user: admin).with_access
      end
      expect(roster.map { |m| m.user.id }).not_to include(member.id)
    end

    it 'really loses access, not just the row' do
      delete revoke_path(member)
      expect(reads_tickets?(member)).to be(false)
    end

    it 'says that the role right was blocked, not that a permission was deleted' do
      delete revoke_path(member)
      expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.blocked'))
    end

    it 'still shows the person on the team page, marked as blocked' do
      delete revoke_path(member)
      get index_path

      expect(response.body).to include('Rolf Testperson')
      expect(response.body).to include(I18n.t('views.organisations.project_permissions.member_row.blocked'))
    end

    it 'offers a way back, so the block is not a one-way door' do
      delete revoke_path(member)
      get index_path

      expect(response.body).to include(I18n.t('views.organisations.project_permissions.member_row.unblock'))
    end

    it 'restores the role-derived access when the block is lifted' do
      delete revoke_path(member)
      permission = ProjectPermission.find_by(project: project, user: member)

      delete permission_path(permission)

      expect(reads_tickets?(member)).to be(true)
      expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.block_lifted'))
    end
  end

  describe 'a member whose access comes only from an explicit grant' do
    let!(:member) { member_in(plain_role, name: 'Dirk') }
    let!(:permission) do
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
    end

    before { sign_in admin }

    it 'leaves the members table and becomes an add-candidate again' do
      delete revoke_path(member)
      get index_path

      expect(response.body).not_to include(revoke_path(member))
      expect(response.body).to include(I18n.t('views.organisations.project_permissions.index.add_member'))
    end

    it 'is off the roster the dashboard TEAM widget reads' do
      delete revoke_path(member)

      roster = ActsAsTenant.with_tenant(organisation) do
        AccessCheck::ProjectTeamMembers.new(project: project.reload, current_user: admin).with_access
      end
      expect(roster.map { |m| m.user.id }).not_to include(member.id)
    end

    it 'drops the grant rather than keeping a blocking row around' do
      delete revoke_path(member)
      expect(ProjectPermission.find_by(id: permission.id)).to be_nil
    end

    it 'reports the plain removal' do
      delete revoke_path(member)
      expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.deleted'))
    end
  end

  # #destroy exists to LIFT a block. Letting it drop a grant that gives something
  # is the original bug: the role right takes over on the next render while the
  # flash reports success. Only Actors::RevokeProjectMember may pick a mechanism.
  describe 'DELETE on a grant that still gives something' do
    let!(:member) { member_in(global_reader_role, name: 'Rolf') }
    let!(:permission) do
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
    end

    before { sign_in admin }

    it 'refuses instead of dropping the row' do
      delete permission_path(permission)

      expect(permission.reload.deleted_at).to be_nil
      expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.use_revoke_instead'))
    end

    it 'leaves the person with the access they had, rather than claiming success' do
      delete permission_path(permission)

      expect(flash[:notice]).to be_nil
      expect(reads_tickets?(member)).to be(true)
    end
  end

  describe 'DELETE on a grant that gives nothing and has no role behind it' do
    let!(:member) { member_in(plain_role, name: 'Dirk') }
    let!(:permission) { create(:project_permission, user: member, project: project) }

    before { sign_in admin }

    it 'drops the row and does NOT claim a block was lifted' do
      delete permission_path(permission)

      expect(ProjectPermission.find_by(id: permission.id)).to be_nil
      expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.deleted'))
    end
  end

  describe 'an account admin' do
    let!(:other_admin) { member_in(admin_role, name: 'Bea') }

    before { sign_in admin }

    it 'gets no remove button, because only the role can take them off' do
      get index_path
      expect(response.body).not_to include(revoke_path(other_admin))
    end

    it 'is refused server-side too' do
      delete revoke_path(other_admin)

      expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.admin_cannot_be_revoked'))
      expect(reads_tickets?(other_admin)).to be(true)
    end
  end

  describe 'authorisation' do
    let!(:member) { member_in(global_reader_role, name: 'Rolf') }
    let!(:outsider) { member_in(plain_role, name: 'Otto') }

    it 'refuses a user without members:write' do
      create(:project_permission, user: outsider, project: project,
                                  members_access: 'read_only', tickets_access: 'read_write')
      sign_in outsider

      delete revoke_path(member)

      expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_manage_permission'))
      expect(ProjectPermission.find_by(project: project, user: member)).to be_nil
    end

    it 'refuses an anonymous request' do
      delete revoke_path(member)
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'does not reach a user of another organisation' do
      other_org = create(:organisation)
      stranger = create(:user)
      ActsAsTenant.with_tenant(other_org) do
        create(:membership, user: stranger, organisation: other_org, role: create(:role, organisation: other_org),
                            active: true)
      end
      sign_in admin

      delete revoke_path(stranger)

      expect(response).to have_http_status(:not_found)
    end
  end

  # Taking someone off the project LEAVES their subscription alone. It used to delete it,
  # because FanoutService merged Project subscribers without re-checking access; the
  # fanout checks now, so the row has no effect while the person is off the project and
  # works again the moment they are back. Nothing has to hand anything back.
  #
  # That is also the only way a removal can be undone honestly: a deleted subscription
  # cannot be told apart from one the person had muted on purpose.
  #
  # The subscriptions here are written by hand on purpose: this suite cannot
  # observe after_create_commit at all (see the model spec), so relying on the
  # auto-subscribe callback to set them up would make every cell below pass
  # whether the code under test runs or not.
  describe 'project subscription across a removal and a return' do
    let!(:member) { member_in(plain_role, name: 'Dirk') }
    let!(:permission) do
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
    end

    before do
      sign_in admin
      NotificationSubscription.system_subscribe(user: member, item: project)
    end

    def subscriptions_for(user)
      ActsAsTenant.with_tenant(organisation) do
        NotificationSubscription.where(user_id: user.id, subscribable: project).count
      end
    end

    it 'keeps the subscription when the person is removed' do
      expect { delete revoke_path(member) }.not_to(change { subscriptions_for(member) })
      expect(subscriptions_for(member)).to eq(1)
    end

    it 'takes the access away all the same, so the kept row cannot deliver' do
      delete revoke_path(member)

      expect(reads_tickets?(member)).to be(false)
    end

    it 'leaves the subscriptions of other members alone' do
      bystander = member_in(plain_role, name: 'Bystander')
      create(:project_permission, user: bystander, project: project, tickets_access: 'read_write')
      NotificationSubscription.system_subscribe(user: bystander, item: project)

      delete revoke_path(member)

      expect(subscriptions_for(bystander)).to eq(1)
    end
  end

  describe 'the activity trail of lifting a block' do
    let!(:member) { member_in(global_reader_role, name: 'Rolf') }

    before { sign_in admin }

    def project_activities(action)
      ActsAsTenant.with_tenant(organisation) do
        Activity.where(action: action, trackable_type: 'Project', trackable_id: project.id).count
      end
    end

    it 'records a grant, because access is handed back' do
      delete revoke_path(member)
      permission = ProjectPermission.find_by(project: project, user: member)

      expect { delete permission_path(permission) }.to change { project_activities('member_added') }.by(1)
    end

    it 'does not record another removal on top of it' do
      delete revoke_path(member)
      permission = ProjectPermission.find_by(project: project, user: member)

      expect { delete permission_path(permission) }.not_to(change { project_activities('member_removed') })
    end
  end

  # Access checks run OUTSIDE the request, where acts_as_tenant has already
  # cleared the tenant; without with_tenant they raise instead of answering.
  def reads_tickets?(user)
    ActsAsTenant.with_tenant(organisation) do
      AccessCheck::ProjectAccessService.new(user.reload, project.reload).can?(:read, :tickets)
    end
  end

  describe 'removing yourself' do
    let!(:self_permission) do
      create(:project_permission, user: admin, project: project, tickets_access: 'read_write')
    end

    before { sign_in admin }

    it 'is not offered on your own row' do
      get index_path
      expect(response.body).not_to include(revoke_path(admin))
    end
  end
end
