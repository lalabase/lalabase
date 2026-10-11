# frozen_string_literal: true

require 'rails_helper'

# =============================================================================
# Admin::UsersController tests - special handling for Admin models
# =============================================================================
#
# CHALLENGE:
# These tests use Admin::Models that bypass acts_as_tenant.
# Normal RSpec patterns don't work without adjustments.
#
# IMPORTANT DESIGN DECISIONS:
# 1. Use regular factories for test data creation
# 2. Test controller operations against Admin::Models
# 3. Disable the tenant system for tests
# 4. Replace object comparisons with ID comparisons
#
# DRAWBACKS OF THIS TEST ARCHITECTURE:
# ⚠️  More complex test setup due to tenant mocking
# ⚠️  ID comparisons instead of object comparisons (less expressive)
# ⚠️  Tests have to account for Admin/frontend model differences
# ⚠️  Additional test complexity from ActsAsTenant.without_tenant blocks
# =============================================================================

RSpec.describe Admin::UsersController, type: :controller do
  # ==========================================================================
  # Test data setup (HYBRID APPROACH)
  # ==========================================================================
  # Uses regular factories for consistent test data,
  # but tests controller operations against Admin::Models

  let(:organisation) { create(:organisation) }
  let(:admin_user) { create(:user) }
  let(:admin_beuser) { create(:beuser) }
  let(:test_user) { create(:user, email: 'test@example.com', active: true) }

  before do
    # Set up routes for admin controllers
    routes.draw do
      namespace :admin do
        resources :users do
          member do
            patch :toggle_active
          end
        end
      end
      devise_for :users
    end
    # ==========================================================================
    # Disable the tenant system for admin tests
    # ==========================================================================
    # CRITICAL: the admin backend must be able to see all tenants
    # RISK: these mocks must NEVER be used in frontend tests!

    # Disable tenant system for admin specs
    allow(ActsAsTenant).to receive(:current_tenant).and_return(nil)
    allow(ActsAsTenant).to receive(:current_tenant=)

    # ==========================================================================
    # Admin authentication simulation
    # ==========================================================================
    # Simulates admin login without real authentication complexity

    allow(controller).to receive(:current_user).and_return(admin_beuser)
    allow(controller).to receive(:logged_in?).and_return(true)
  end

  describe 'GET #index' do
    context 'without filter' do
      # Compares RECORDS, not relations. In Rails `relation == relation` compares the generated
      # SQL, so this went red — with an unreadable diff of identical-looking objects — the moment
      # the action gained .without_system to keep the Lalabase system account out of the listing.
      # The SQL differed; the rows did not. Asserting on to_a states the actual contract, and the
      # second expectation pins the exclusion that caused the confusion in the first place.
      it 'assigns all users ordered by created_at, without the system account' do
        users = create_list(:user, 3)

        get :index

        assigned = assigns(:users)
        expect(assigned.map(&:id)).to include(*users.map(&:id))
        expect(assigned.map(&:created_at)).to eq(assigned.map(&:created_at).sort)
        expect(assigned.map(&:email)).not_to include(::User::SystemAccount::EMAIL)
      end
    end

    context "with status filter 'active'" do
      it 'assigns only active users' do
        active_user = create(:user, active: true)
        inactive_user = create(:user, active: false)

        get :index, params: { status: 'active' }

        # Check IDs since Admin::User and User are different classes but same data
        user_ids = assigns(:users).map(&:id)
        expect(user_ids).to include(active_user.id)
        expect(user_ids).not_to include(inactive_user.id)
      end
    end

    context "with status filter 'inactive'" do
      it 'assigns only inactive users' do
        active_user = create(:user, active: true)
        inactive_user = create(:user, active: false)

        get :index, params: { status: 'inactive' }

        # Check IDs since Admin::User and User are different classes but same data
        user_ids = assigns(:users).map(&:id)
        expect(user_ids).to include(inactive_user.id)
        expect(user_ids).not_to include(active_user.id)
      end
    end
  end

  describe 'GET #new' do
    it 'assigns new user and organisation' do
      get :new
      expect(assigns(:user)).to be_a_new(Admin::User)
      expect(assigns(:organisation)).to be_a_new(Admin::Organisation)
    end
  end

  describe 'POST #create' do
    let(:valid_user_params) do
      {
        first_name: 'Max',
        last_name: 'Mustermann',
        email: 'max.mustermann@example.com',
        active: true
      }
    end

    let(:valid_organisation_params) do
      {
        name: 'Test Organisation GmbH',
        subdomain: 'test-org',
        domain: 'test.example.com'
      }
    end

    context 'with valid parameters' do
      it 'creates a new user and organisation' do
        expect do
          post :create, params: {
            user: valid_user_params,
            organisation: valid_organisation_params
          }
        end.to change(User, :count).by(1)
                                   .and change(Organisation, :count).by(1)
                                                                    .and change(Membership, :count).by(1)
      end

      it 'creates user as admin of the organisation' do
        post :create, params: {
          user: valid_user_params,
          organisation: valid_organisation_params
        }

        # ==========================================================================
        # IMPORTANT: ID comparisons instead of object comparisons
        # ==========================================================================
        # Admin::Models and regular models are different classes
        # even when they use the same table. Hence ID comparisons are necessary.

        user = User.last
        organisation = Organisation.last

        # ActsAsTenant.without_tenant is necessary to load memberships
        # REASON: the regular User model is tenant-restricted
        ActsAsTenant.without_tenant do
          membership = user.memberships.joins(:role).first
          expect(membership).to be_present
          expect(membership.organisation_id).to eq(organisation.id)
          expect(membership.active).to be true
          expect(membership.role.title).to eq(Role::ACCOUNT_ADMIN_TITLE)
        end
      end

      it 'creates user with specified active status' do
        post :create, params: {
          user: valid_user_params.merge(active: false),
          organisation: valid_organisation_params
        }

        user = User.last
        expect(user.active).to be false
      end

      it 'generates a temporary password' do
        post :create, params: {
          user: valid_user_params,
          organisation: valid_organisation_params
        }

        user = User.last
        expect(user.encrypted_password).to be_present
      end

      it 'redirects with success message including temporary password' do
        post :create, params: {
          user: valid_user_params,
          organisation: valid_organisation_params
        }

        expect(response).to redirect_to(admin_users_path)
        expect(flash[:notice]).to include('erfolgreich erstellt')
        expect(flash[:notice]).to include('Temporäres Passwort')
      end
    end

    context 'with invalid user parameters' do
      it 'does not create user or organisation when email is missing' do
        expect do
          post :create, params: {
            user: valid_user_params.merge(email: ''),
            organisation: valid_organisation_params
          }
        end.not_to change(User, :count)

        expect do
          post :create, params: {
            user: valid_user_params.merge(email: ''),
            organisation: valid_organisation_params
          }
        end.not_to change(Organisation, :count)
      end

      it 'renders new template with error' do
        post :create, params: {
          user: valid_user_params.merge(email: ''),
          organisation: valid_organisation_params
        }

        expect(response).to render_template(:new)
        expect(flash[:alert]).to include('Fehler beim Erstellen')
      end
    end

    context 'with invalid organisation parameters' do
      it 'does not create user or organisation when organisation name is missing' do
        expect do
          post :create, params: {
            user: valid_user_params,
            organisation: valid_organisation_params.merge(name: '')
          }
        end.not_to change(User, :count)

        expect do
          post :create, params: {
            user: valid_user_params,
            organisation: valid_organisation_params.merge(name: '')
          }
        end.not_to change(Organisation, :count)
      end

      it 'rolls back user creation when organisation creation fails' do
        allow_any_instance_of(Admin::Organisation).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Admin::Organisation.new))

        expect do
          post :create, params: {
            user: valid_user_params,
            organisation: valid_organisation_params
          }
        end.not_to change(User, :count)
      end
    end
  end

  describe 'PATCH #toggle_active' do
    context 'with active user' do
      it 'deactivates the user' do
        user = create(:user, active: true)

        expect do
          patch :toggle_active, params: { id: user.id }
        end.to change { user.reload.active }.from(true).to(false)
      end

      it 'redirects with success message' do
        user = create(:user, active: true)

        patch :toggle_active, params: { id: user.id }

        expect(response).to redirect_to(admin_users_path)
        expect(flash[:notice]).to include('deaktiviert')
        expect(flash[:notice]).to include(user.email)
      end
    end

    context 'with inactive user' do
      it 'activates the user' do
        user = create(:user, active: false)

        expect do
          patch :toggle_active, params: { id: user.id }
        end.to change { user.reload.active }.from(false).to(true)
      end

      it 'redirects with success message' do
        user = create(:user, active: false)

        patch :toggle_active, params: { id: user.id }

        expect(response).to redirect_to(admin_users_path)
        expect(flash[:notice]).to include('aktiviert')
        expect(flash[:notice]).to include(user.email)
      end
    end

    context 'with non-existent user' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          patch :toggle_active, params: { id: 'non-existent-id' }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when update fails' do
      it 'redirects with error message' do
        user = create(:user, active: true)
        allow_any_instance_of(Admin::User).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(Admin::User.new))

        patch :toggle_active, params: { id: user.id }

        expect(response).to redirect_to(admin_users_path)
        expect(flash[:alert]).to include('Fehler beim Ändern des Status')
      end
    end
  end

  # ==========================================================================
  # GET #show (MOST COMPLEX TEST SETUP)
  # ==========================================================================
  # These tests demonstrate the complexity of the Admin/frontend model separation

  describe 'GET #show' do
    # ==========================================================================
    # Test data creation with ActsAsTenant.without_tenant
    # ==========================================================================
    # PROBLEM: tenant-restricted models can't be created normally
    # SOLUTION: use ActsAsTenant.without_tenant for data setup
    # DRAWBACK: tests become harder to read and maintain

    let!(:show_test_user) { create(:user, first_name: 'Test', last_name: 'User', email: 'test@example.com') }
    let!(:show_organisation) { ActsAsTenant.without_tenant { create(:organisation, name: 'Test Organisation') } }
    let!(:show_project) { ActsAsTenant.without_tenant { create(:project, organisation: show_organisation, name: 'Test Project') } }

    before do
      # Create membership and project permission for the test user
      # REQUIRED: without ActsAsTenant.without_tenant these factories would fail
      ActsAsTenant.without_tenant do
        role = create(:role, organisation: show_organisation, title: 'Account Admin')
        create(:membership, user: show_test_user, organisation: show_organisation, role: role, active: true)
        create(:project_permission, user: show_test_user, project: show_project,
                                    tickets_access: :read_write, notes_access: :read_only, documents_access: :no_access)
      end
    end

    it 'successfully loads user details' do
      get :show, params: { id: show_test_user.id }

      expect(response).to have_http_status(:success)
      # Check that user ID matches since Admin::User and User are different classes
      expect(assigns(:user).id).to eq(show_test_user.id)
      expect(assigns(:user)).to be_a(Admin::User)
      expect(assigns(:memberships)).to be_present
      expect(assigns(:project_permissions)).to be_present
      expect(assigns(:user_stats)).to be_present
    end

    it 'calculates user statistics correctly' do
      get :show, params: { id: show_test_user.id }

      stats = assigns(:user_stats)
      expect(stats[:total_organisations]).to eq(1)
      expect(stats[:active_memberships]).to eq(1)
      expect(stats[:total_projects_with_access]).to eq(1)
      expect(stats[:member_since]).to eq(show_test_user.created_at)
    end

    it 'loads memberships with organisations and roles' do
      get :show, params: { id: show_test_user.id }

      memberships = assigns(:memberships)
      expect(memberships.first.organisation.id).to eq(show_organisation.id)
      expect(memberships.first.role.title).to eq('Account Admin')
    end

    it 'loads project permissions with projects' do
      get :show, params: { id: show_test_user.id }

      permissions = assigns(:project_permissions)
      expect(permissions.first.project.id).to eq(show_project.id)
      expect(permissions.first.tickets_access).to eq('read_write')
      expect(permissions.first.notes_access).to eq('read_only')
    end

    it 'handles user without memberships gracefully' do
      user_without_orgs = create(:user, email: 'lonely@example.com')

      get :show, params: { id: user_without_orgs.id }

      expect(response).to have_http_status(:success)
      expect(assigns(:memberships)).to be_empty
      expect(assigns(:project_permissions)).to be_empty
      expect(assigns(:user_stats)[:total_organisations]).to eq(0)
    end

    it 'returns 404 for non-existent user' do
      expect do
        get :show, params: { id: 'non-existent-id' }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    context 'with multiple organisations and projects' do
      let!(:second_organisation) { ActsAsTenant.without_tenant { create(:organisation, name: 'Second Organisation') } }
      let!(:second_project) { ActsAsTenant.without_tenant { create(:project, organisation: second_organisation, name: 'Second Project') } }

      before do
        # Add user to second organisation
        ActsAsTenant.without_tenant do
          role2 = create(:role, organisation: second_organisation, title: 'Member')
          create(:membership, user: show_test_user, organisation: second_organisation, role: role2, active: false)
          create(:project_permission, user: show_test_user, project: second_project,
                                      tickets_access: :read_only, notes_access: :read_write, documents_access: :read_only)
        end
      end

      it 'counts all organisations and memberships correctly' do
        get :show, params: { id: show_test_user.id }

        stats = assigns(:user_stats)
        expect(stats[:total_organisations]).to eq(2)
        expect(stats[:active_memberships]).to eq(1) # Only one active membership
        expect(stats[:total_projects_with_access]).to eq(2)
      end

      it 'orders memberships by organisation name' do
        get :show, params: { id: show_test_user.id }

        memberships = assigns(:memberships)
        organisation_names = memberships.map(&:organisation).map(&:name)
        expect(organisation_names).to eq(['Second Organisation', 'Test Organisation'])
      end

      it 'orders project permissions by project name' do
        get :show, params: { id: show_test_user.id }

        permissions = assigns(:project_permissions)
        project_names = permissions.map(&:project).map(&:name)
        expect(project_names).to eq(['Second Project', 'Test Project'])
      end
    end
  end

  # ==========================================================================
  # DELETE #destroy - Account Deletion Tests
  # ==========================================================================
  describe 'DELETE #destroy' do
    let(:deletion_target_user) do
      ActsAsTenant.without_tenant do
        create(:user, email: 'delete_target@example.com', first_name: 'Delete', last_name: 'Target')
      end
    end
    let(:deletion_organisation) { ActsAsTenant.without_tenant { create(:organisation, name: 'Deletion Test Org') } }
    let(:deletion_membership) do
      ActsAsTenant.without_tenant do
        create(:membership, user: deletion_target_user, organisation: deletion_organisation)
      end
    end

    before do
      deletion_membership # Create membership
    end

    context 'when admin provides correct email confirmation' do
      let(:valid_deletion_params) do
        {
          id: deletion_target_user.id,
          email_confirmation: deletion_target_user.email,
          reason: 'GDPR deletion request'
        }
      end

      it 'successfully deletes the user account' do
        delete :destroy, params: valid_deletion_params

        deletion_target_user.reload
        expect(deletion_target_user.deleted_at).not_to be_nil
        expect(response).to redirect_to(admin_users_path)
      end

      it 'anonymizes user email' do
        delete :destroy, params: valid_deletion_params
        deletion_target_user.reload
        expect(deletion_target_user.email).to match(/deleted_user_[0-9a-f-]+@deleted\.local/)
      end

      it 'sets deletion_recommended flag' do
        delete :destroy, params: valid_deletion_params
        expect(deletion_target_user.reload.deletion_recommended).to be true
      end

      it 'creates audit trail entry' do
        expect do
          delete :destroy, params: valid_deletion_params
        end.to change { UserDeletion.count }.by(1)

        audit_entry = UserDeletion.last
        expect(audit_entry.deleted_user_id).to eq(deletion_target_user.id)
        expect(audit_entry.deleter).to eq(admin_beuser)
        expect(audit_entry.source).to eq('backend')
        expect(audit_entry.reason).to eq('GDPR deletion request')
      end

      it 'removes all user memberships' do
        expect do
          delete :destroy, params: valid_deletion_params
        end.to change { deletion_target_user.memberships.count }.to(0)
      end

      it 'redirects to admin users index with success notice' do
        delete :destroy, params: valid_deletion_params
        expect(response).to redirect_to(admin_users_path)
        expect(flash[:notice]).to include('wurde erfolgreich gelöscht')
      end
    end

    context 'when DeleteAccountService fails' do
      before do
        allow_any_instance_of(DeleteAccountService).to receive(:call).and_return(false)
        allow_any_instance_of(DeleteAccountService).to receive(:errors).and_return(['Service validation failed'])
      end

      it 'handles service errors gracefully' do
        delete :destroy, params: {
          id: deletion_target_user.id,
          email_confirmation: deletion_target_user.email,
          reason: 'Test deletion'
        }

        expect(response).to redirect_to(admin_users_path)
        expect(flash[:alert]).to include('Service validation failed')
      end
    end

    context 'when user does not exist' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          delete :destroy, params: {
            id: 'non-existent-uuid',
            email_confirmation: 'test@example.com'
          }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  # ==========================================================================
  # Admin::User Model Tests - can_be_deleted_by? method
  # ==========================================================================
  describe 'Admin::User#can_be_deleted_by?' do
    let(:test_admin_user) do
      ActsAsTenant.without_tenant do
        create(:user, email: 'test_admin@example.com')
      end
    end

    context 'with valid backend admin' do
      it 'returns true for non-deleted user' do
        admin_user = Admin::User.find(test_admin_user.id)
        expect(admin_user.can_be_deleted_by?(admin_beuser)).to be true
      end

      it 'returns false for already deleted user' do
        test_admin_user.update!(deleted_at: Time.current)
        admin_user = Admin::User.find(test_admin_user.id)
        expect(admin_user.can_be_deleted_by?(admin_beuser)).to be false
      end
    end

    context 'with invalid requester' do
      it 'returns false for nil requester' do
        admin_user = Admin::User.find(test_admin_user.id)
        expect(admin_user.can_be_deleted_by?(nil)).to be false
      end

      it 'returns false for non-Beuser requester' do
        regular_user = ActsAsTenant.without_tenant { create(:user) }
        admin_user = Admin::User.find(test_admin_user.id)
        expect(admin_user.can_be_deleted_by?(regular_user)).to be false
      end
    end
  end
end
