# frozen_string_literal: true

require 'rails_helper'

# S4 / F3 regression guard: the share page must render its "revoke" button for
# existing shares. Before the fix the button pointed at a non-existent
# `smart_folder_share_path`, so the page crashed the moment a folder had a share —
# which also meant a share could never be revoked via the UI. The revoke route
# (`unshare`) was added in this slice.
RSpec.describe 'Organisations::SmartFolders share', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:owner) { create(:user) }
  let(:colleague) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, user: owner, organisation: organisation, project: project, target_object_type: 'Ticket')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: owner, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: colleague, organisation: organisation, role: admin_role, active: true)
    create(:project_permission, user: owner, project: project, tickets_access: 'read_write')
    create(:project_permission, user: colleague, project: project, tickets_access: 'read_only')
    sign_in owner
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'renders the share page with the revoke button when a share exists' do
    ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: folder, user: colleague) }

    get share_organisation_smart_folder_path(organisation, folder)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(unshare_user_organisation_smart_folder_path(organisation, folder, colleague.id))
  end

  it 'revokes a share via the unshare route' do
    ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: folder, user: colleague) }

    expect do
      delete unshare_user_organisation_smart_folder_path(organisation, folder, colleague.id)
    end.to change {
      ActsAsTenant.with_tenant(organisation) { folder.smart_folder_shares.where(user_id: colleague.id).count }
    }.from(1).to(0)

    expect(response).to redirect_to(share_organisation_smart_folder_path(organisation, folder))
  end
end
