# frozen_string_literal: true

require 'rails_helper'

# The endpoint behind "Änderung speichern" for a view's columns
# (doc/spaltenwahl_plan.md, S3): cols[] as the picker wrote it into the address.
# JSON only, one trivial write. A key the reader may not see in this project is
# refused as a whole (422): sliced away, the bar would record a list as saved
# that the server never stored. The policy is SmartFolderPolicy#update?; a denial
# comes back as the app's usual redirect, which the bar reads as "not saved".
RSpec.describe 'Organisations::SmartFolders#columns', type: :request do
  let(:organisation) { create(:organisation) }
  let(:owner) { create(:user) }
  let(:reader) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:json) { { 'ACCEPT' => 'application/json' } }
  let(:legacy_columns) { { 'table_columns' => %w[number title assignees], 'list_columns' => { 'cells' => %w[tags], 'metadata' => [] } } }

  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, name: 'Eilig', organisation: organisation, project: project, user: owner,
                            target_object_type: 'Ticket', display_columns: legacy_columns)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def sign_in_as(user, role)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  def stored_columns
    ActsAsTenant.with_tenant(organisation) { folder.reload.display_columns }
  end

  it 'stores the list for the owner, required first, and retires the legacy second list' do
    sign_in_as(owner, member_role)

    patch columns_organisation_smart_folder_path(organisation, folder),
          params: { cols: %w[created_at title number assignees] }, headers: json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('success' => true, 'columns' => %w[number title created_at assignees])
    expect(stored_columns).to eq('table_columns' => %w[number title created_at assignees])
  end

  it 'refuses a key the reader may not see in this project with 422 and leaves the list alone' do
    sign_in_as(owner, member_role)

    patch columns_organisation_smart_folder_path(organisation, folder), params: { cols: %w[assignees nope] }, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['success']).to be false
    expect(stored_columns).to eq(legacy_columns)
  end

  it 'refuses a request without a list' do
    sign_in_as(owner, member_role)

    patch columns_organisation_smart_folder_path(organisation, folder), params: {}, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(stored_columns).to eq(legacy_columns)
  end

  it 'denies a reader the folder is shared with read-only (SmartFolderPolicy#update?)' do
    sign_in_as(reader, member_role)
    ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: folder, user: reader, can_edit: false) }

    patch columns_organisation_smart_folder_path(organisation, folder), params: { cols: %w[created_at] }, headers: json

    expect(response).to have_http_status(:found)
    expect(stored_columns).to eq(legacy_columns)
  end

  it 'lets an editor the folder is shared with save the list' do
    sign_in_as(reader, member_role)
    ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: folder, user: reader, can_edit: true) }

    patch columns_organisation_smart_folder_path(organisation, folder), params: { cols: %w[created_at] }, headers: json

    expect(response).to have_http_status(:ok)
    expect(stored_columns).to eq('table_columns' => %w[number title created_at])
  end

  # An org-wide folder has no project; the list sends its project_id, and the
  # project must be one the reader may select (an admin sees them all).
  it 'reads the attribute names of an org-wide folder from the project the list sends along' do
    sign_in_as(owner, admin_role)
    ActsAsTenant.with_tenant(organisation) { folder.update!(project: nil) }

    patch columns_organisation_smart_folder_path(organisation, folder), params: { cols: %w[created_at] }, headers: json
    expect(response).to have_http_status(:unprocessable_content)

    patch columns_organisation_smart_folder_path(organisation, folder), params: { cols: %w[created_at], project_id: project.id }, headers: json
    expect(response).to have_http_status(:ok)
    expect(stored_columns).to eq('table_columns' => %w[number title created_at])
  end
end
