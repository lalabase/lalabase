# frozen_string_literal: true

require 'rails_helper'

# The rename endpoint behind the filter bar's tab menu
# (doc/filterleiste_s5_s8_plan.md, S5). Name only, JSON only: the full update
# action assumes the whole form and would null a view's own columns. The
# policy is SmartFolderPolicy#update?; a denial comes back as the app's usual
# redirect, which the bar reads as "not saved".
RSpec.describe 'Organisations::SmartFolders#rename', type: :request do
  let(:organisation) { create(:organisation) }
  let(:owner) { create(:user) }
  let(:reader) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:json) { { 'ACCEPT' => 'application/json' } }

  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, name: 'Eilig', organisation: organisation, project: project, user: owner, target_object_type: 'Ticket')
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def sign_in_as(user, role)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  it 'renames for the owner and answers the new name' do
    sign_in_as(owner, member_role)

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: '  Ganz eilig ' }, headers: json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('success' => true, 'name' => 'Ganz eilig')
    expect(folder.reload.name).to eq('Ganz eilig')
  end

  it 'refuses a blank name with 422 and keeps the old one' do
    sign_in_as(owner, member_role)

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: '   ' }, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['success']).to be false
    expect(folder.reload.name).to eq('Eilig')
  end

  it 'leaves the display columns of the view alone (the reason for the endpoint)' do
    sign_in_as(owner, member_role)
    ActsAsTenant.with_tenant(organisation) { folder.update!(display_columns: { 'table_columns' => %w[title status] }) }

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: 'Neu' }, headers: json

    expect(folder.reload.display_columns).to eq('table_columns' => %w[title status])
  end

  it 'denies a reader the folder is shared with read-only (SmartFolderPolicy#update?)' do
    sign_in_as(reader, member_role)
    ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: folder, user: reader, can_edit: false) }

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: 'Meins' }, headers: json

    expect(response).to have_http_status(:found)
    expect(folder.reload.name).to eq('Eilig')
  end

  # SmartFolderPolicy::Scope keeps another user's PRIVATE folder out of every
  # list, admins included (the privacy contract in the policy); set_smart_folder
  # looks the folder up through that scope, so an admin reaches only a folder
  # that is public or shared. The per-record update? then says yes.
  it 'lets an account admin rename a public folder that is not theirs' do
    sign_in_as(reader, admin_role)
    ActsAsTenant.with_tenant(organisation) { folder.update!(is_public: true) }

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: 'Vom Admin' }, headers: json

    expect(response).to have_http_status(:ok)
    expect(folder.reload.name).to eq('Vom Admin')
  end

  it 'keeps another user\'s private folder out of an admin\'s reach (the scope, not the policy, answers)' do
    sign_in_as(reader, admin_role)

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: 'Vom Admin' }, headers: json

    expect(response).to have_http_status(:found)
    expect(folder.reload.name).to eq('Eilig')
  end

  it 'answers a folder outside the policy scope with the usual redirect, not a rename' do
    sign_in_as(reader, member_role)

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: 'Fremd' }, headers: json

    expect(response).to have_http_status(:found)
    expect(folder.reload.name).to eq('Eilig')
  end

  it 'refuses a name longer than the field allows (255) with 422 and the reason' do
    sign_in_as(owner, member_role)

    patch rename_organisation_smart_folder_path(organisation, folder), params: { name: 'x' * 256 }, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['success']).to be false
    expect(response.parsed_body['error']).to be_present
    expect(folder.reload.name).to eq('Eilig')
  end

  it 'never reaches a folder of an organisation the caller is no member of' do
    other_org = create(:organisation)
    other = ActsAsTenant.with_tenant(other_org) do
      create(:smart_folder, name: 'Fremd', organisation: other_org, user: create(:user), target_object_type: 'Ticket')
    end
    sign_in_as(owner, member_role)

    patch rename_organisation_smart_folder_path(other_org, other), params: { name: 'Meins' }, headers: json

    expect(response).not_to have_http_status(:ok)
    expect(ActsAsTenant.with_tenant(other_org) { other.reload.name }).to eq('Fremd')
  end

  # The delete behind the same menu: the bar reads a 204 without a redirect as
  # done, and a denial's redirect (followed to HTML) as failure.
  describe 'the delete from the tab menu (JSON)' do
    it 'answers the owner with 204 and removes the folder' do
      sign_in_as(owner, member_role)

      delete organisation_smart_folder_path(organisation, folder), headers: json

      expect(response).to have_http_status(:no_content)
      expect(ActsAsTenant.with_tenant(organisation) { SmartFolder.exists?(folder.id) }).to be false
    end

    it 'answers a reader the folder is shared with read-only with the redirect and keeps it' do
      sign_in_as(reader, member_role)
      ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: folder, user: reader, can_edit: false) }

      delete organisation_smart_folder_path(organisation, folder), headers: json

      expect(response).to have_http_status(:found)
      expect(ActsAsTenant.with_tenant(organisation) { SmartFolder.exists?(folder.id) }).to be true
    end
  end

  describe 'the expert filter saved from the knowledge page' do
    it 'returns to the knowledge list (return_to=knowledge)' do
      sign_in_as(owner, member_role)

      patch organisation_smart_folder_path(organisation, folder),
            params: { smart_folder: { name: 'Eilig' }, return_to: 'knowledge' }

      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project))
    end

    # The modal's form is submitted by Turbo, so the answer the reader gets is
    # the stream, not the redirect above; it must name the same address.
    it 'returns there through the Turbo Stream the modal actually takes' do
      sign_in_as(owner, member_role)

      patch organisation_smart_folder_path(organisation, folder),
            params: { smart_folder: { name: 'Eilig' }, return_to: 'knowledge' },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(organisation_project_knowledge_index_path(organisation, project))
      expect(response.body).not_to include(organisation_project_notes_path(organisation, project))
    end
  end
end
