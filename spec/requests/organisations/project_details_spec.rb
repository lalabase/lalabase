# frozen_string_literal: true

require 'rails_helper'

# The project settings page (edit) is a pure hub of navigation cards — the
# name + description form lives on the details subpage. These specs pin the
# split: the hub must not carry form fields, the subpage must; saving returns
# to the hub (not the project dashboard), and the subpage enforces the same
# update? permission as the hub.
RSpec.describe 'Project settings hub and details subpage', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: admin_role, active: true) }
    user
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in admin
  end
  after { ActsAsTenant.current_tenant = nil }

  describe 'settings hub (edit)' do
    it 'shows the details card linking to the subpage instead of the form' do
      get edit_organisation_project_path(organisation, project)

      expect(response.body).to include(I18n.t('views.organisations.projects.edit.details_title'))
      expect(response.body).to include(details_organisation_project_path(organisation, project))
      expect(response.body).not_to include('name="project[name]"')
    end

    it 'summarizes the current description on the card' do
      project.update!(description: 'Relaunch der Kundenplattform')
      get edit_organisation_project_path(organisation, project)
      expect(response.body).to include('Relaunch der Kundenplattform')
    end

    it 'shows a placeholder when no description exists' do
      project.update!(description: nil)
      get edit_organisation_project_path(organisation, project)
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.details_no_description'))
    end
  end

  describe 'details subpage' do
    it 'renders the form with a back link to the settings hub' do
      get details_organisation_project_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="project[name]"')
      expect(response.body).to include(edit_organisation_project_path(organisation, project))
    end

    # A member who can SEE the project (read access to one area) but may not change its
    # properties. Without the read access a member never reaches update?: set_project
    # checks show? first and sends them to the project list (next example). That is what
    # this example measured by accident once ProjectPolicy#show? asked for area access.
    it 'denies members without project update permission, as the hub does' do
      member_role = create(:role, organisation: organisation)
      member = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
        create(:project_permission, user: member, project: project, tickets_access: :read_only)
      end
      sign_in member

      get details_organisation_project_path(organisation, project)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))

      get edit_organisation_project_path(organisation, project)
      expect(response).to redirect_to(root_path)
    end

    it 'sends a member without any access to the project list before any permission check' do
      member_role = create(:role, organisation: organisation)
      member = create(:user)
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: member, organisation: organisation, role: member_role, active: true) }
      sign_in member

      get details_organisation_project_path(organisation, project)
      expect(response).to redirect_to(organisation_projects_path(organisation))
    end
  end

  describe 'update' do
    it 'redirects back to the settings hub on success' do
      patch organisation_project_path(organisation, project), params: { project: { name: 'Neuer Name' } }

      expect(response).to redirect_to(edit_organisation_project_path(organisation, project))
      expect(project.reload.name).to eq('Neuer Name')
    end

    it 're-renders the details form on validation failure' do
      patch organisation_project_path(organisation, project), params: { project: { name: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('name="project[name]"')
    end
  end
end
