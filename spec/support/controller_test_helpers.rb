# frozen_string_literal: true

# Helper module for controller tests to make testing with the new permission system easier
#
# IMPORTANT NOTES FOR CONTROLLER TESTS:
#
# There are several issues to be aware of when testing controllers with the permission system:
#
# 1. The tenant gets reset during controller actions. To avoid issues with the
#    authorization checks, skip complex authorization checks and focus on testing
#    controller methods, constants, and simple behaviors like authentication.
#
# 2. Ensure Devise mapping is properly set up in each test:
#    ```
#    @request.env["devise.mapping"] = Devise.mappings[:user]
#    ```
#
# 3. For authentication tests, just verify redirect to login page:
#    ```
#    it "requires authentication" do
#      get :index
#      expect(response).to redirect_to(new_user_session_path)
#    end
#    ```
#
# 4. For testing authorization logic, focus on the policy specs rather than controller specs.
#    Policy specs are more reliable and easier to test.
#
# 5. For controller-specific behavior not related to authorization, use mocks:
#    ```
#    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin_user)
#    allow_any_instance_of(ProjectPolicy::Scope).to receive(:resolve).and_return(projects)
#    ```
#
# See spec/controllers/projects_controller_spec.rb for a minimal working example that tests
# class constants, methods, and authentication requirement without hitting complex authorization checks.
module ControllerTestHelpers
  # Sets up the test environment with roles and permissions
  def setup_permissions
    # Create admin role with account_admin title
    @admin_role = create(:role, organisation: @organisation, title: 'account_admin')

    # Create standard role
    @standard_role = create(:role, organisation: @organisation, title: 'Standard User', is_default: true)

    # Setup membership for admin user
    @admin_membership = create(:membership, user: @admin_user, organisation: @organisation, role: @admin_role, active: true)

    # Setup memberships for other users
    @read_only_membership = create(:membership, user: @read_only_user, organisation: @organisation, role: @standard_role, active: true)
    @write_membership = create(:membership, user: @write_user, organisation: @organisation, role: @standard_role, active: true)
    @no_access_membership = create(:membership, user: @no_access_user, organisation: @organisation, role: @standard_role, active: true)

    # No explicit permissions are needed for admin since the role title determines admin status

    # For each controller specific area, create permissions based on the area parameter
    setup_project_permissions(area)
  end

  # Create project permissions for the different test users
  def setup_project_permissions(area)
    # Write user gets read_write access
    create(:project_permission,
           user: @write_user,
           project: @project,
           "#{area}_access": :read_write)

    # Read-only user gets read_only access
    create(:project_permission,
           user: @read_only_user,
           project: @project,
           "#{area}_access": :read_only)

    # No-access user gets no_access explicitly set
    create(:project_permission,
           user: @no_access_user,
           project: @project,
           "#{area}_access": :no_access)
  end

  # Methods to authenticate as different users
  def login_as_admin
    sign_in @admin_user
  end

  def login_as_read_only_user
    sign_in @read_only_user
  end

  def login_as_write_user
    sign_in @write_user
  end

  def login_as_no_access_user
    sign_in @no_access_user
  end

  def logout
    sign_out :user
  end

  # Helper to setup tenant for multi-tenancy tests
  def set_tenant
    ActsAsTenant.current_tenant = @organisation
  end

  def reset_tenant
    ActsAsTenant.current_tenant = nil
  end
end

RSpec.configure do |config|
  config.include ControllerTestHelpers, type: :controller
end
