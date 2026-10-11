# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::ProjectPermissions', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }

  let(:admin) { create(:user) }
  let(:member_with_write) { create(:user) }
  let(:member_with_read) { create(:user) }
  let(:member_without_access) { create(:user) }
  let(:target_user) { create(:user) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  # Memberships
  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:member_with_write_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member_with_write, organisation: organisation, role: member_role, active: true)
    end
  end

  let!(:member_with_read_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member_with_read, organisation: organisation, role: member_role, active: true)
    end
  end

  let!(:member_without_access_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member_without_access, organisation: organisation, role: member_role, active: true)
    end
  end

  let!(:target_user_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: target_user, organisation: organisation, role: member_role, active: true)
    end
  end

  # Member with members:read_write needs change_project_properties for authorize @project, :update?
  let!(:change_project_permission) do
    create(:permission, role: member_role, category: 'projects', action: 'change_project_properties', allowed: true)
  end

  # Project permissions
  let!(:write_member_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission,
             user: member_with_write, project: project,
             members_access: 'read_write', tickets_access: 'read_write')
    end
  end

  let!(:read_member_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission,
             user: member_with_read, project: project,
             members_access: 'read_only', tickets_access: 'read_write')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  # Helper paths
  let(:index_path) { organisation_project_project_permissions_path(organisation, project) }
  let(:info_path) { info_organisation_project_project_permissions_path(organisation, project) }

  def permission_path(permission)
    organisation_project_project_permission_path(organisation, project, permission)
  end

  def time_sessions_settings_path(permission)
    time_sessions_settings_organisation_project_project_permission_path(organisation, project, permission)
  end

  def update_time_sessions_settings_path(permission)
    update_time_sessions_settings_organisation_project_project_permission_path(organisation, project, permission)
  end

  # ──────────────────────────────────────────────
  # GET #index
  # ──────────────────────────────────────────────
  describe 'GET #index' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get index_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      # index checks area_access?(:members, :read), then authorize @project, :update?
      # member has change_project_properties + project_permission → update? passes
      it 'returns success' do
        get index_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member with members:no_access' do
      before do
        create(:project_permission, user: member_without_access, project: project,
                                    members_access: 'no_access', tickets_access: 'read_write')
        sign_in member_without_access
      end

      it 'redirects with no_view_permission alert' do
        get index_path
        expect(response).to redirect_to(organisation_project_path(organisation, project))
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_view_permission'))
      end
    end

    context 'as member with no project permission at all' do
      before { sign_in member_without_access }

      it 'redirects (no members area access)' do
        get index_path
        expect(response).to redirect_to(organisation_project_path(organisation, project))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # POST #create
  # ──────────────────────────────────────────────
  describe 'POST #create' do
    let(:valid_params) do
      {
        project_permission: {
          user_id: target_user.id,
          tickets_access: 'read_write',
          notes_access: 'read_only',
          chats_access: 'no_access',
          documents_access: 'read_write',
          members_access: 'no_access'
        }
      }
    end

    context 'as admin' do
      before { sign_in admin }

      it 'creates a new project permission' do
        expect do
          post index_path, params: valid_params
        end.to change(ProjectPermission, :count).by(1)
      end

      it 'redirects with created notice' do
        post index_path, params: valid_params
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.created'))
      end

      it 'sets the correct access levels' do
        post index_path, params: valid_params
        permission = ProjectPermission.find_by(user: target_user, project: project)
        expect(permission.tickets_access).to eq('read_write')
        expect(permission.notes_access).to eq('read_only')
        expect(permission.chats_access).to eq('no_access')
        expect(permission.documents_access).to eq('read_write')
        expect(permission.members_access).to eq('no_access')
      end

      context 'when restoring a soft-deleted permission' do
        let!(:archived_permission) do
          perm = create(:project_permission, user: target_user, project: project,
                                             tickets_access: 'read_only', notes_access: 'read_write')
          perm.update!(deleted_at: 1.day.ago)
          perm
        end

        it 'restores the archived permission instead of creating new' do
          expect do
            post index_path, params: valid_params
          end.not_to change(ProjectPermission.unscoped.where(project: project, user: target_user), :count)

          archived_permission.reload
          expect(archived_permission.deleted_at).to be_nil
        end

        it 'redirects with restored notice' do
          post index_path, params: valid_params
          expect(response).to redirect_to(index_path)
          expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.restored'))
        end
      end

      context 'when user already has an active permission (duplicate)' do
        before do
          create(:project_permission, user: target_user, project: project)
        end

        it 'does not create a duplicate' do
          expect do
            post index_path, params: valid_params
          end.not_to change(ProjectPermission, :count)
        end

        it 'renders index with validation error' do
          post index_path, params: valid_params
          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    context 'as member with members:read_write access' do
      before { sign_in member_with_write }

      it 'creates a new permission' do
        expect do
          post index_path, params: valid_params
        end.to change(ProjectPermission, :count).by(1)
      end

      it 'redirects with created notice' do
        post index_path, params: valid_params
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.created'))
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      it 'denies access (no_manage_permission)' do
        post index_path, params: valid_params
        expect(response).to redirect_to(organisation_project_path(organisation, project))
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_manage_permission'))
      end

      it 'does not create a permission' do
        expect do
          post index_path, params: valid_params
        end.not_to change(ProjectPermission, :count)
      end
    end

    context 'as member without any project access' do
      before { sign_in member_without_access }

      it 'denies access' do
        post index_path, params: valid_params
        expect(response).to redirect_to(organisation_project_path(organisation, project))
      end

      it 'does not create a permission' do
        expect do
          post index_path, params: valid_params
        end.not_to change(ProjectPermission, :count)
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        post index_path, params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # PATCH #update
  # ──────────────────────────────────────────────
  describe 'PATCH #update' do
    let!(:existing_permission) do
      create(:project_permission, user: target_user, project: project,
                                  tickets_access: 'read_only', notes_access: 'no_access')
    end

    let(:update_params) do
      {
        project_permission: {
          tickets_access: 'read_write',
          notes_access: 'read_write'
        }
      }
    end

    context 'as admin' do
      before { sign_in admin }

      it 'updates the permission' do
        patch permission_path(existing_permission), params: update_params
        existing_permission.reload
        expect(existing_permission.tickets_access).to eq('read_write')
        expect(existing_permission.notes_access).to eq('read_write')
      end

      it 'redirects with updated notice' do
        patch permission_path(existing_permission), params: update_params
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.updated'))
      end

      context 'when no permissions actually change' do
        let(:same_params) do
          {
            project_permission: {
              tickets_access: 'read_only',
              notes_access: 'no_access'
            }
          }
        end

        it 'still redirects with success' do
          patch permission_path(existing_permission), params: same_params
          expect(response).to redirect_to(index_path)
          expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.updated'))
        end
      end

      context 'when permission does not belong to this project' do
        let(:other_project) { create(:project, organisation: organisation) }
        let!(:other_permission) { create(:project_permission, user: target_user, project: other_project) }

        it 'returns 404' do
          patch permission_path(other_permission), params: update_params
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context 'as member with members:read_write access' do
      before { sign_in member_with_write }

      it 'updates the permission' do
        patch permission_path(existing_permission), params: update_params
        existing_permission.reload
        expect(existing_permission.tickets_access).to eq('read_write')
      end

      it 'redirects with updated notice' do
        patch permission_path(existing_permission), params: update_params
        expect(response).to redirect_to(index_path)
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      it 'denies access (no_manage_permission)' do
        patch permission_path(existing_permission), params: update_params
        expect(response).to redirect_to(organisation_project_path(organisation, project))
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_manage_permission'))
      end

      it 'does not update the permission' do
        patch permission_path(existing_permission), params: update_params
        expect(existing_permission.reload.tickets_access).to eq('read_only')
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        patch permission_path(existing_permission), params: update_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # DELETE #destroy
  # ──────────────────────────────────────────────
  # #destroy drops an explicit grant that gives NOTHING, and only that. Dropping
  # one can never take access away; it hands back whatever the role allows, which
  # is what "Sperre aufheben" means. Dropping a grant that gives something is the
  # bug this endpoint was fixed for, so it is refused and sent to #revoke, whose
  # actor picks the mechanism. See project_permissions_revoke_spec.rb.
  describe 'DELETE #destroy' do
    # A grant that gives nothing: the only shape #destroy may drop.
    let!(:existing_permission) { create(:project_permission, user: target_user, project: project) }

    # A grant that still gives something, on a different user so the unique index
    # on (user_id, project_id) stays satisfied.
    let(:granted_user) { create(:user) }
    let!(:granting_permission) do
      create(:membership, user: granted_user, organisation: organisation, role: member_role, active: true)
      create(:project_permission, user: granted_user, project: project, tickets_access: 'read_write')
    end

    context 'as admin' do
      before { sign_in admin }

      it 'soft-deletes the permission (sets deleted_at)' do
        delete permission_path(existing_permission)
        existing_permission.reload
        expect(existing_permission.deleted_at).to be_present
      end

      it 'removes from default scope' do
        delete permission_path(existing_permission)
        expect(ProjectPermission.find_by(id: existing_permission.id)).to be_nil
      end

      it 'keeps the record in unscoped queries' do
        delete permission_path(existing_permission)
        expect(ProjectPermission.unscoped.find_by(id: existing_permission.id)).to be_present
      end

      it 'redirects with deleted notice' do
        delete permission_path(existing_permission)
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.deleted'))
      end

      it 'refuses a grant that still gives something, rather than reporting a removal' do
        delete permission_path(granting_permission)

        expect(granting_permission.reload.deleted_at).to be_nil
        expect(flash[:notice]).to be_nil
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.use_revoke_instead'))
      end

      context 'when permission does not belong to this project' do
        let(:other_project) { create(:project, organisation: organisation) }
        let!(:other_permission) { create(:project_permission, user: target_user, project: other_project) }

        it 'returns 404' do
          delete permission_path(other_permission)
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context 'as member with members:read_write access' do
      before { sign_in member_with_write }

      it 'soft-deletes the permission' do
        delete permission_path(existing_permission)
        expect(existing_permission.reload.deleted_at).to be_present
      end

      it 'redirects with deleted notice' do
        delete permission_path(existing_permission)
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.deleted'))
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      # Uses the droppable row on purpose: without it the refusal above would
      # stop the request anyway and this would prove nothing about authorization.
      it 'denies access (no_manage_permission)' do
        delete permission_path(existing_permission)
        expect(response).to redirect_to(organisation_project_path(organisation, project))
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_manage_permission'))
      end

      it 'does not soft-delete the permission' do
        delete permission_path(existing_permission)
        expect(existing_permission.reload.deleted_at).to be_nil
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        delete permission_path(existing_permission)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #time_sessions_settings
  # ──────────────────────────────────────────────
  describe 'GET #time_sessions_settings' do
    let!(:existing_permission) do
      create(:project_permission, user: target_user, project: project,
                                  tickets_access: 'read_write')
    end

    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get time_sessions_settings_path(existing_permission)
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member with members:read_write access' do
      before { sign_in member_with_write }

      it 'returns success' do
        get time_sessions_settings_path(existing_permission)
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      it 'denies access (no_manage_permission)' do
        get time_sessions_settings_path(existing_permission)
        expect(response).to redirect_to(organisation_project_path(organisation, project))
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_manage_permission'))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get time_sessions_settings_path(existing_permission)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # PATCH #update_time_sessions_settings
  # ──────────────────────────────────────────────
  describe 'PATCH #update_time_sessions_settings' do
    let!(:existing_permission) do
      create(:project_permission, user: target_user, project: project,
                                  tickets_access: 'read_write')
    end

    let(:time_params) do
      {
        time_session_permission: {
          can_create_own: true,
          can_view_own: true,
          can_edit_own: false,
          can_delete_own: false,
          can_view_all: true,
          can_edit_all: false,
          can_delete_all: false
        }
      }
    end

    context 'as admin' do
      before { sign_in admin }

      it 'updates time session permissions and redirects' do
        patch update_time_sessions_settings_path(existing_permission), params: time_params
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.time_sessions_updated'))
      end

      it 'persists the time session permission values' do
        patch update_time_sessions_settings_path(existing_permission), params: time_params
        time_perm = target_user.time_session_permission_for(project)
        expect(time_perm).to be_persisted
        expect(time_perm.can_edit_own).to be false
        expect(time_perm.can_view_all).to be true
        expect(time_perm.can_delete_all).to be false
      end

      it 'creates a time_session_permission if none exists' do
        expect do
          patch update_time_sessions_settings_path(existing_permission), params: time_params
        end.to change(TimeSessionPermission, :count).by(1)
      end

      context 'when time_session_permission already exists' do
        let!(:time_perm) do
          create(:time_session_permission, user: target_user, project: project,
                                           can_view_all: false, can_edit_own: true)
        end

        it 'updates existing permission without creating new' do
          expect do
            patch update_time_sessions_settings_path(existing_permission), params: time_params
          end.not_to change(TimeSessionPermission, :count)

          time_perm.reload
          expect(time_perm.can_view_all).to be true
          expect(time_perm.can_edit_own).to be false
        end
      end
    end

    context 'as member with members:read_write access' do
      before { sign_in member_with_write }

      it 'updates and redirects' do
        patch update_time_sessions_settings_path(existing_permission), params: time_params
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.time_sessions_updated'))
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      it 'denies access (no_manage_permission)' do
        patch update_time_sessions_settings_path(existing_permission), params: time_params
        expect(response).to redirect_to(organisation_project_path(organisation, project))
        expect(flash[:alert]).to eq(I18n.t('flash.project_permissions.no_manage_permission'))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        patch update_time_sessions_settings_path(existing_permission), params: time_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #info
  # ──────────────────────────────────────────────
  describe 'GET #info' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get info_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member with members:read_write access' do
      before { sign_in member_with_write }

      it 'returns success' do
        get info_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member with members:read_only access' do
      before { sign_in member_with_read }

      # info uses show? (not members:write) — accessible with any area read access
      it 'returns success' do
        get info_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as member without any project access' do
      before { sign_in member_without_access }

      it 'denies access (no show? permission)' do
        get info_path
        expect(response).to redirect_to(organisation_project_path(organisation, project))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get info_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
