# frozen_string_literal: true

require 'rails_helper'

# The description field on the project details form (settings subpage) hides
# behind an "add description" disclosure when blank (most projects never get
# one) and renders expanded when a description exists — otherwise the saved
# text would look lost behind the link.
RSpec.describe 'Project details — collapsed description field', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: admin_role, active: true) }
    user
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in admin
  end
  after { ActsAsTenant.current_tenant = nil }

  let(:add_description_label) { I18n.t('organisations.projects.form.add_description') }

  it 'hides a blank description behind the disclosure trigger' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, description: nil) }
    get details_organisation_project_path(organisation, project)
    expect(response.body).to include(add_description_label)
    expect(response.body).to include('data-controller="collapse"')
  end

  it 'renders an existing description expanded, without the disclosure trigger' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, description: 'Relaunch der Kundenplattform') }
    get details_organisation_project_path(organisation, project)
    expect(response.body).to include('Relaunch der Kundenplattform')
    expect(response.body).not_to include(add_description_label)
  end
end
