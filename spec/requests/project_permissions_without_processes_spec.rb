# frozen_string_literal: true

require 'rails_helper'

# What: the project permissions grid without the Prozesse area.
# Why:  Slice 1a of Prozesse (#374) put a "Prozesse" column into this grid in
#       August 2026 while no screen of the feature ever shipped (1b, #392, was
#       closed). The core went public without it; Prozesse comes back as one
#       complete pull request. The page is proven present (another area's
#       column renders) before the absence is asserted.
RSpec.describe 'Organisations::ProjectPermissions without Prozesse', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let(:member) { create(:user) }
  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation,
                          role: create(:role, organisation: organisation), active: true)
    end
  end
  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, project: project, user: member)
    end
  end

  before do
    sign_in admin
    ActsAsTenant.current_tenant = organisation
    Current.user = admin
  end

  after { Current.reset }

  it 'shows the other areas and no Prozesse column' do
    get organisation_project_project_permissions_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('views.organisations.project_permissions.areas.meetings'))
    expect(response.body).not_to include('Prozesse')
  end

  it 'knows no processes area any more' do
    expect(ProjectPermission.access_areas).not_to include(:processes)
    expect(ProjectPermission.new).not_to respond_to(:processes_access)
  end
end
