# frozen_string_literal: true

require 'rails_helper'

# Three boundaries inside one organisation:
#   - it always keeps an active account admin (demote, deactivate, self-deletion)
#   - a role manager who is no account admin grants and removes only rights they
#     hold themselves, and does not edit their own role
#   - a project permission cannot be moved to another user through update
# Every refusal has a control that goes through.
RSpec.describe 'Organisation privilege boundaries', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) { create(:user) }
  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, organisation: organisation, user: admin, role: admin_role, active: true)
    end
  end
  let(:standard_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, title: 'Standard') } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # A request resets the tenant; read the result back inside it.
  def role_of(membership)
    ActsAsTenant.with_tenant(organisation) { membership.reload.role }
  end

  def last_admin_message
    I18n.t('flash.memberships.last_active_admin', organisation: organisation.name)
  end

  describe 'the last active account admin' do
    before { sign_in admin }

    it 'cannot demote themselves' do
      patch organisation_membership_path(organisation, admin_membership), params: { membership: { role_id: standard_role.id } }

      expect(role_of(admin_membership)).to eq(admin_role)
      expect(response.body).to include(CGI.escapeHTML(last_admin_message))
    end

    it 'cannot deactivate themselves' do
      patch organisation_membership_path(organisation, admin_membership), params: { membership: { active: '0' } }

      expect(admin_membership.reload.active).to be(true)
    end

    it 'cannot delete their own account' do
      allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(0)

      post account_deletion_path, params: { current_password: admin.password, reason: 'x' }

      expect(admin.reload.deleted_at).to be_nil
      expect(flash[:alert]).to include(last_admin_message)
    end

    context 'with a second active admin' do
      let(:other_admin) { create(:user) }
      let!(:other_membership) do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, organisation: organisation, user: other_admin, role: admin_role, active: true)
        end
      end

      it 'can demote themselves' do
        patch organisation_membership_path(organisation, admin_membership), params: { membership: { role_id: standard_role.id } }

        expect(role_of(admin_membership)).to eq(standard_role)
      end

      it 'can demote the other admin' do
        patch organisation_membership_path(organisation, other_membership), params: { membership: { role_id: standard_role.id } }

        expect(role_of(other_membership)).to eq(standard_role)
      end

      it 'can delete their own account' do
        allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(0)

        post account_deletion_path, params: { current_password: admin.password, reason: 'x' }

        expect(admin.reload.deleted_at).to be_present
      end

      # An admin whose account is deactivated cannot act for the organisation,
      # so they do not count as the one that remains.
      it 'does not count a deactivated account as the remaining admin' do
        other_admin.update_columns(active: false)

        patch organisation_membership_path(organisation, admin_membership), params: { membership: { role_id: standard_role.id } }

        expect(role_of(admin_membership)).to eq(admin_role)
      end
    end
  end

  describe 'a role manager who is no account admin' do
    let(:manager) { create(:user) }
    let(:manager_role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation, title: 'Role manager').tap do |role|
          create(:permission, role: role, category: 'accounts', action: 'add_edit_delete_roles', allowed: true)
          create(:permission, role: role, category: 'projects', action: 'create_new_projects', allowed: true)
        end
      end
    end
    let!(:manager_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, organisation: organisation, user: manager, role: manager_role, active: true)
      end
    end

    before { sign_in manager }

    def allowed?(role, category, action)
      ActsAsTenant.with_tenant(organisation) do
        role.permissions.reload.find_by(category: category, action: action)&.allowed || false
      end
    end

    def save_role(role, permissions)
      patch organisation_role_path(organisation, role), params: { role: { title: role.title }, permissions: permissions }
    end

    it 'grants a right they hold' do
      save_role(standard_role, { projects: { create_new_projects: '1' } })

      expect(allowed?(standard_role, 'projects', 'create_new_projects')).to be(true)
    end

    it 'cannot grant a right they do not hold' do
      save_role(standard_role, { accounts: { manage_users: '1' } })

      expect(allowed?(standard_role, 'accounts', 'manage_users')).to be(false)
    end

    it 'cannot take away a right they do not hold' do
      ActsAsTenant.with_tenant(organisation) do
        create(:permission, role: standard_role, category: 'accounts', action: 'manage_users', allowed: true)
      end

      save_role(standard_role, { accounts: { manage_users: '0' } })

      expect(allowed?(standard_role, 'accounts', 'manage_users')).to be(true)
    end

    # The form sends every checkbox. Unchanged values for rights the manager
    # lacks are no change and must not block the rights they do hold.
    it 'saves a full form that leaves foreign rights as they are' do
      save_role(standard_role, { accounts: { manage_users: '0' }, projects: { create_new_projects: '1' } })

      expect(allowed?(standard_role, 'projects', 'create_new_projects')).to be(true)
    end

    it 'cannot change their own role, not even with a right they hold' do
      save_role(manager_role, { projects: { create_new_projects: '0' } })

      expect(allowed?(manager_role, 'projects', 'create_new_projects')).to be(true)
    end

    it 'cannot edit their own role' do
      save_role(manager_role, { projects: { delete_projects: '1' } })

      expect(allowed?(manager_role, 'projects', 'delete_projects')).to be(false)
    end

    it 'can make a role the default whose rights they hold' do
      post set_default_organisation_role_path(organisation, standard_role)

      expect(ActsAsTenant.with_tenant(organisation) { standard_role.reload.is_default }).to be(true)
    end

    it 'cannot make a role the default that holds rights they lack' do
      ActsAsTenant.with_tenant(organisation) do
        create(:permission, role: standard_role, category: 'accounts', action: 'manage_users', allowed: true)
      end

      post set_default_organisation_role_path(organisation, standard_role)

      expect(ActsAsTenant.with_tenant(organisation) { standard_role.reload.is_default }).to be(false)
    end

    context 'when the account admin edits the same role' do
      before { sign_in admin }

      it 'grants any right' do
        save_role(standard_role, { accounts: { manage_users: '1' } })

        expect(allowed?(standard_role, 'accounts', 'manage_users')).to be(true)
      end
    end
  end

  describe 'updating a project permission' do
    let(:project) { create(:project, organisation: organisation) }
    let(:member) { create(:user) }
    let(:other_member) { create(:user) }
    let!(:permission) do
      ActsAsTenant.with_tenant(organisation) do
        [member, other_member].each do |user|
          create(:membership, organisation: organisation, user: user, role: standard_role, active: true)
        end
        create(:project_permission, project: project, user: member, tickets_access: :read_only)
      end
    end

    before { sign_in admin }

    it 'changes the access, but never the user the row belongs to' do
      patch organisation_project_project_permission_path(organisation, project, permission),
            params: { project_permission: { tickets_access: 'read_write', user_id: other_member.id } }

      ActsAsTenant.with_tenant(organisation) { permission.reload }
      expect(permission.tickets_access).to eq('read_write')
      expect(permission.user_id).to eq(member.id)
    end
  end
end
