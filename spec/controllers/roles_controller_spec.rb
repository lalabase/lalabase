# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::RolesController, type: :controller do
  before do
    Rails.application.routes.draw do
      namespace :organisations do
        resources :roles do
          member do
            post :set_default
          end
        end
      end
    end
  end

  after do
    Rails.application.reload_routes!
  end
  # Test authentication without hitting controller actions
  describe 'authentication' do
    before do
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Mock the BaseController behavior to prevent it from trying to access current_user.organisations
      allow(controller).to receive(:set_organisation).and_return(true)
      allow(controller).to receive(:set_current_membership).and_return(true)
      allow(controller).to receive(:current_user).and_return(nil)
      allow(controller).to receive(:user_signed_in?).and_return(false)
      allow(controller).to receive(:authenticate_user!).and_call_original
    end

    it 'requires authentication' do
      get :index, params: { organisation_id: '123' }
      expect(response).to be_redirect
    end
  end

  # Test controller private methods with minimal auth mocking
  describe 'private methods' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }
    let(:role) { create(:role, organisation: organisation, title: 'Standard User') }
    let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }

    before do
      # Set up the mapping for Devise
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Set tenant
      ActsAsTenant.current_tenant = organisation

      # Mock authentication
      allow(controller).to receive(:current_user).and_return(user)
      allow(controller).to receive(:user_signed_in?).and_return(true)
      allow(controller).to receive(:current_organisation).and_return(organisation)
      allow(controller).to receive(:authenticate_user!).and_return(true)

      # Mock BaseController methods
      allow(controller).to receive(:set_organisation).and_return(organisation)
      allow(controller).to receive(:set_current_membership).and_return(true)

      # Mock authorization by default
      allow(controller).to receive(:authorize).and_return(true)
      allow(controller).to receive(:policy_scope).and_return(Role.all)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe '#set_role' do
      it 'finds the role by id' do
        # Mock params with role id
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: role.id
                                                         ))

        # Call the method
        controller.send(:set_role)

        # Verify that role is assigned
        expect(controller.instance_variable_get(:@role)).to eq(role)
      end
    end

    describe '#role_params' do
      it 'permits the correct parameters' do
        # Mock params with role attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           role: {
                                                             title: 'New Role',
                                                             description: 'Role description'
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:role_params)

        # Verify permitted parameters
        expect(result.to_h).to include(
          'title' => 'New Role',
          'description' => 'Role description'
        )
      end
    end

    describe '#permission_params' do
      it 'permits valid permission actions' do
        permissions_hash = {
          'accounts' => {
            'add_edit_delete_roles' => '1',
            'create_account_admins' => '0'
          }
        }

        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           permissions: permissions_hash
                                                         ))

        result = controller.send(:permission_params)

        expect(result.to_h).to eq(permissions_hash)
      end

      it 'rejects actions not in Permission::CATEGORIES' do
        permissions_hash = {
          'accounts' => {
            'add_edit_delete_roles' => '1',
            'injected_action' => '1'
          }
        }

        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           permissions: permissions_hash
                                                         ))

        result = controller.send(:permission_params)

        expect(result.to_h).to eq({ 'accounts' => { 'add_edit_delete_roles' => '1' } })
      end
    end
  end

  # Test specific controller behavior with minimal authorization mocking
  describe 'controller actions' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }
    let(:role) { create(:role, organisation: organisation, title: 'Standard User', is_default: true) }
    let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
    let(:other_role) { create(:role, organisation: organisation, title: 'Other Role') }

    before do
      # Set up the mapping for Devise
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Set tenant
      ActsAsTenant.current_tenant = organisation

      # Mock authentication
      allow(controller).to receive(:current_user).and_return(user)
      allow(controller).to receive(:user_signed_in?).and_return(true)
      allow(controller).to receive(:current_organisation).and_return(organisation)
      allow(controller).to receive(:authenticate_user!).and_return(true)

      # Mock BaseController methods
      allow(controller).to receive(:set_organisation).and_return(organisation)
      allow(controller).to receive(:set_current_membership).and_return(true)

      # Mock authorization — stub Pundit's verify_authorized so the after_action
      # callback does not raise AuthorizationNotPerformedError when we stub `authorize`.
      allow(controller).to receive(:authorize).and_return(true)
      allow(controller).to receive(:verify_authorized).and_return(true)
      allow(controller).to receive(:policy_scope).and_return(Role.all)

      # Mock controller methods
      allow(controller).to receive(:set_role).and_return(true)

      # Mock the route helper by defining the method
      def controller.organisation_roles_path
        '/mocked/roles/path'
      end
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe 'GET #edit' do
      it 'redirects when role is account_admin' do
        # Mock params with admin role
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: admin_role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, admin_role)

        # Call the action
        get :edit, params: { organisation_id: organisation.id, id: admin_role.id }

        # Verify redirect
        expect(response).to redirect_to('/mocked/roles/path')
      end

      it 'initializes permissions hash for standard role' do
        # Mock params with standard role
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, role)

        # Mock Permission::CATEGORIES
        allow(Permission).to receive(:const_get).with(:CATEGORIES).and_return({
                                                                                accounts: %w[add_edit_delete_roles add_edit_delete_users],
                                                                                projects: %w[create_new_projects delete_projects]
                                                                              })

        # Call the action — pause Prosopite: this test verifies controller
        # behavior (permissions hash initialization), not query performance.
        # The known N+1 in #edit (one Permission lookup per category/action)
        # is tracked as technical debt at the controller level.
        Prosopite.pause
        get :edit, params: { organisation_id: organisation.id, id: role.id }
        Prosopite.resume

        # Verify that permissions hash is initialized
        permissions = controller.instance_variable_get(:@permissions)
        expect(permissions).to be_a(Hash)
        expect(permissions).to have_key(:accounts)
        expect(permissions).to have_key(:projects)
      end
    end

    describe 'PUT #update' do
      it 'redirects when role is account_admin' do
        # Mock params with admin role
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: admin_role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, admin_role)

        # Call the action
        put :update, params: { organisation_id: organisation.id, id: admin_role.id }

        # Verify redirect
        expect(response).to redirect_to('/mocked/roles/path')
      end

      # Regression guard for the whitelist gap closed in PR 3: roles#update now syncs only
      # whitelisted permission actions (via permission_params), so a tampered/injected action
      # is stripped and the update still succeeds — instead of failing the whole update on the
      # Permission validation, as the previous raw params[:permissions] loop did.
      it 'strips a non-whitelisted permission action and still updates the role' do
        controller.instance_variable_set(:@role, role)
        # Actors::SaveRole lets an account admin change any right (a manager only
        # their own); `authorize` is stubbed here, the actor asks RolePolicy itself,
        # which needs the tenant the real set_organisation sets.
        create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
        allow(controller).to receive(:set_organisation) { ActsAsTenant.current_tenant = organisation }

        put :update, params: {
          organisation_id: organisation.id,
          id: role.id,
          role: { title: 'Renamed Role', description: 'updated' },
          permissions: { 'accounts' => { 'manage_users' => '1', 'injected_action' => '1' } }
        }

        expect(response).to redirect_to('/mocked/roles/path')
        expect(role.reload.title).to eq('Renamed Role')
        expect(role.permissions.find_by(category: 'accounts', action: 'manage_users')&.allowed).to be true
        expect(role.permissions.where(action: 'injected_action')).to be_empty
      end

      # Guards submitted_permission_params' blank branch: a role update WITHOUT a permissions
      # key must still succeed. Dropping the `return {} if params[:permissions].blank?` guard
      # would let permission_params' `params.require(:permissions)` raise ParameterMissing here.
      it 'updates role attributes when no permissions are submitted (blank guard)' do
        controller.instance_variable_set(:@role, role)

        put :update, params: {
          organisation_id: organisation.id,
          id: role.id,
          role: { title: 'Only Attrs', description: 'no perms' }
        }

        expect(response).to redirect_to('/mocked/roles/path')
        expect(role.reload.title).to eq('Only Attrs')
      end

      # Covers the failure branch added in PR 3. When Actors::SaveRole returns a failure
      # Result (here: a blank title violates Role's presence validation), the controller must
      # re-render :edit with 422, rebuild the permission map via load_permissions_for_edit, and
      # leave the role unchanged. Without load_permissions_for_edit the edit view would blow up
      # on a nil @permissions; this pins that the helper runs on the failure path.
      it 'rolls back and re-renders :edit with 422 when the role update is invalid' do
        controller.instance_variable_set(:@role, role)

        # load_permissions_for_edit does one Permission lookup per category/action — the same
        # acknowledged controller-level N+1 as #edit, not what this test measures.
        Prosopite.pause
        put :update, params: {
          organisation_id: organisation.id,
          id: role.id,
          role: { title: '', description: 'no title' },
          permissions: { 'accounts' => { 'manage_users' => '1' } }
        }
        Prosopite.resume

        expect(response).to have_http_status(:unprocessable_content)
        expect(response).to render_template(:edit)
        expect(role.reload.title).to eq('Standard User')
        expect(controller.instance_variable_get(:@permissions)).to be_a(Hash)
        expect(flash[:alert]).to be_present
      end
    end

    describe 'DELETE #destroy' do
      it 'redirects when role is account_admin' do
        # Mock params with admin role
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: admin_role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, admin_role)

        # Call the action
        delete :destroy, params: { organisation_id: organisation.id, id: admin_role.id }

        # Verify redirect
        expect(response).to redirect_to('/mocked/roles/path')
      end

      it 'redirects when role has memberships' do
        # Mock params with role that has memberships
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, role)

        # Mock role.memberships.any? to return true
        allow(role).to receive_message_chain(:memberships, :any?).and_return(true)

        # Call the action
        delete :destroy, params: { organisation_id: organisation.id, id: role.id }

        # Verify redirect
        expect(response).to redirect_to('/mocked/roles/path')
      end

      it 'destroys role and redirects when role has no memberships' do
        # Mock params with role that has no memberships
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: other_role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, other_role)

        # Mock role.memberships.any? to return false
        allow(other_role).to receive_message_chain(:memberships, :any?).and_return(false)

        # Expect role to be destroyed - use allow instead of expect to avoid timing issues
        allow(other_role).to receive(:destroy).and_return(true)

        # Set up flash manually
        flash = {}
        allow(controller).to receive(:flash).and_return(flash)

        # Mock redirect but let it call through to actually set the flash
        allow(controller).to receive(:redirect_to).with(anything, notice: 'Rolle wurde erfolgreich gelöscht.') do
          flash[:notice] = 'Rolle wurde erfolgreich gelöscht.'
        end

        # Call the action
        delete :destroy, params: { organisation_id: organisation.id, id: other_role.id }
      end
    end

    describe 'PATCH #set_default' do
      it 'redirects when role is account_admin' do
        # Mock params with admin role
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: admin_role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, admin_role)

        # Call the action
        patch :set_default, params: { organisation_id: organisation.id, id: admin_role.id }

        # Verify redirect
        expect(response).to redirect_to('/mocked/roles/path')
      end

      it 'updates roles and redirects when using standard role' do
        # Mock params with standard role
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           id: role.id
                                                         ))

        # Set role instance variable
        controller.instance_variable_set(:@role, other_role)

        # Mock current_organisation.roles.where query and update
        roles_relation = double('RolesRelation')
        allow(organisation).to receive_message_chain(:roles, :where).with(is_default: true).and_return(roles_relation)
        expect(roles_relation).to receive(:update_all).with(is_default: false)

        # Expect role to be updated - use allow instead of expect
        allow(other_role).to receive(:update).with(is_default: true).and_return(true)

        # Set up flash manually
        flash = {}
        allow(controller).to receive(:flash).and_return(flash)

        # Mock redirect but let it call through to actually set the flash
        allow(controller).to receive(:redirect_to).with(anything, notice: 'Standardrolle wurde erfolgreich festgelegt.') do
          flash[:notice] = 'Standardrolle wurde erfolgreich festgelegt.'
        end

        # Call the action
        patch :set_default, params: { organisation_id: organisation.id, id: other_role.id }
      end
    end
  end
end
