# frozen_string_literal: true

require 'rails_helper'

# The custom actions download_plain_text/create_version/destroy_version called `authorize
# @document` WITHOUT an explicit action → Pundit derived `download_plain_text?` /
# `create_version?` / `destroy_version?`, which DocumentPolicy does not know → NoMethodError
# (500 for EVERY caller, authorization effectively not enforced). These specs pin
# the correct action per endpoint: read=:show?, create version=:update?, delete=:destroy?.
RSpec.describe 'Organisations document version authorization', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  let(:document) { ActsAsTenant.with_tenant(organisation) { create(:document, project: project, organisation: organisation) } }
  let(:version) do
    ActsAsTenant.with_tenant(organisation) do
      create(:document_version, document: document, organisation: organisation, plain_text_version: 'hello text')
    end
  end

  def member_with(documents_access)
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, user: u, project: project, documents_access: documents_access)
    end
    u
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # The tenant is reset by the Rack middleware after the request; counts of
  # tenanted models must therefore run within the tenant context again.
  def version_count
    ActsAsTenant.with_tenant(organisation) { document.document_versions.count }
  end

  describe 'GET download_plain_text (read = :show?)' do
    it 'serves the text to a member with read access' do
      sign_in member_with('read_only')

      get download_plain_text_organisation_project_document_path(organisation, project, document, version_id: version.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('hello text')
    end

    it 'denies a member without document access (redirect, not 500)' do
      no_access = create(:user)
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: no_access, organisation: organisation, role: standard_role, active: true) }
      sign_in no_access

      get download_plain_text_organisation_project_document_path(organisation, project, document, version_id: version.id)

      expect(response).to have_http_status(:found)
    end
  end

  describe 'DELETE destroy_version (delete = :destroy?)' do
    it 'lets a member with write access delete a version' do
      version
      other = ActsAsTenant.with_tenant(organisation) { create(:document_version, document: document, organisation: organisation) }
      sign_in member_with('read_write')

      expect do
        delete destroy_version_organisation_project_document_path(organisation, project, document, version_id: other.id)
      end.to change { version_count }.by(-1)
    end

    it 'denies a read-only member (redirect, no deletion)' do
      version
      sign_in member_with('read_only')

      expect do
        delete destroy_version_organisation_project_document_path(organisation, project, document, version_id: version.id)
      end.not_to(change { version_count })
      expect(response).to have_http_status(:found)
    end
  end

  describe 'POST create_version (add version = :update?)' do
    it 'lets a member with write access create a version' do
      version
      sign_in member_with('read_write')
      file = Rack::Test::UploadedFile.new(StringIO.new('v2 content'), 'text/plain', true, original_filename: 'v2.txt')

      expect do
        post create_version_organisation_project_document_path(organisation, project, document),
             params: { document_version: { title: 'V2', document_version_file: file } }
      end.to change { version_count }.by(1)
    end

    it 'denies a read-only member (redirect, no new version)' do
      version
      sign_in member_with('read_only')

      expect do
        post create_version_organisation_project_document_path(organisation, project, document),
             params: { document_version: { title: 'V2', description: 'x' } }
      end.not_to(change { version_count })
      expect(response).to have_http_status(:found)
    end
  end

  # doc/dokumentansicht_plan.md, S2: "als aktuell setzen" modifies the document
  # (its title is the current version's), so it asks :update? like create_version.
  describe 'PATCH set_current_version (set current = :update?)' do
    let(:other) { ActsAsTenant.with_tenant(organisation) { create(:document_version, document: document, organisation: organisation) } }

    before { ActsAsTenant.with_tenant(organisation) { document.update!(current_version: other) } }

    it 'lets a member with write access move the pointer' do
      sign_in member_with('read_write')

      patch set_current_version_organisation_project_document_path(organisation, project, document, version_id: version.id)

      expect(ActsAsTenant.with_tenant(organisation) { document.reload.current_version_id }).to eq(version.id)
    end

    it 'denies a read-only member (redirect, pointer unchanged)' do
      sign_in member_with('read_only')

      patch set_current_version_organisation_project_document_path(organisation, project, document, version_id: version.id)

      expect(response).to have_http_status(:found)
      expect(ActsAsTenant.with_tenant(organisation) { document.reload.current_version_id }).to eq(other.id)
    end
  end
end
