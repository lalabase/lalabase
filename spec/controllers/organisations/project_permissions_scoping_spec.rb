# frozen_string_literal: true

require 'rails_helper'

# R3 regression guard: the project permissions grid (and the add/create path) must not
# enumerate or target users from projects the current user cannot access. The Team Members
# list stays complete; the add-candidates and the create resolution are scoped to
# users_visible_to. (Controller spec so the grid collection is asserted directly.)
RSpec.describe Organisations::ProjectPermissionsController, type: :controller do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  def member_in(role = standard_role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:project_a) { create(:project, organisation: organisation) } # managed here
  let(:project_b) { create(:project, organisation: organisation) } # foreigner only
  let(:project_c) { create(:project, organisation: organisation) } # manager + addable share

  let(:manager) { member_in }
  let(:addable) { member_in } # shares project_c with manager → visible, not on project_a
  let(:foreigner) { member_in } # only on project_b → invisible to manager

  before do
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :projects do
          resources :project_permissions
        end
      end
    end

    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: manager, project: project_a, members_access: 'read_write', tickets_access: 'read_only')
    create(:project_permission, user: manager, project: project_c, tickets_access: 'read_only')
    create(:project_permission, user: addable, project: project_c, tickets_access: 'read_only')
    create(:project_permission, user: foreigner, project: project_b, tickets_access: 'read_only')
    sign_in manager
  end

  after do
    ActsAsTenant.current_tenant = nil
    # routes.draw above replaces the global route set; restore it so request specs that run
    # afterwards (e.g. project_access_scoping_spec) keep their named routes.
    Rails.application.reload_routes!
  end

  describe 'GET #index' do
    it 'scopes the grid to visible users and excludes foreign-project users' do
      get :index, params: { organisation_id: organisation.id, project_id: project_a.id }

      # The grid is now built from resolver view-models (team members + add candidates).
      resolved_users = (assigns(:members) + assigns(:candidates)).map(&:user)
      expect(resolved_users).to include(manager, addable)
      expect(resolved_users).not_to include(foreigner)
    end
  end
end
