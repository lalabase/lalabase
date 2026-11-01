# frozen_string_literal: true

require 'rails_helper'

# Authorized file proxy: file downloads must be secured against project access (and thus
# the org boundary) — not just via a secret, never-expiring blob link.
# The proxy runs under Organisations::BaseController (Devise + tenant + Pundit).
RSpec.describe 'Organisations::FileDownloads', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  let(:document) { ActsAsTenant.with_tenant(organisation) { create(:document, project: project_a, organisation: organisation) } }
  let(:version) { ActsAsTenant.with_tenant(organisation) { create(:document_version, document: document, organisation: organisation) } }

  def download(kind: 'document_version', id: version.id, org: organisation)
    get organisation_file_download_path(organisation_id: org.id, kind: kind, id: id)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'GET show' do
    it 'serves the bytes to a member with document read access' do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      sign_in member

      download

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('dummy content')
      expect(response.media_type).to eq('text/plain')
      expect(response.headers['Content-Disposition']).to include('test.txt')
    end

    it 'returns 404 (no existence leak) for a member without access to the project' do
      sign_in member # no ProjectPermission

      download

      expect(response).to have_http_status(:not_found)
    end

    it 'redirects unauthenticated requests to login (no bytes)' do
      download

      expect(response).to have_http_status(:found)
      expect(response.body).not_to include('dummy content')
    end

    # The example above was green while every such request ended as a 500 outside the
    # tests (found in a browser, 2026-09-30). This controller streams, so its action runs
    # in a thread of its own (ActionController::Live, through ActiveStorage::Streaming).
    # Devise answers a missing login with `throw :warden`, and the catch for it sits in
    # a middleware of the REQUEST thread: in the action's thread the throw arrives
    # nowhere. Rails runs a live action inline in tests (action_controller/test_case.rb
    # redefines new_controller_thread), which is exactly what hid it. This example takes
    # the thread back.
    context 'with the action in a thread of its own, as outside the tests' do
      before do
        allow_any_instance_of(Organisations::FileDownloadsController)
          .to receive(:new_controller_thread) { |controller, &action| controller.send(:original_new_controller_thread, &action) }
      end

      it 'redirects unauthenticated requests to login, and does not answer 500' do
        # No record is needed, and none would be visible: the thread has its own
        # database connection, outside this example's transaction. The login is
        # checked before anything is looked up.
        download(id: SecureRandom.uuid)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    it 'returns 404 for a file from a different organisation (cross-org)' do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      other_org = create(:organisation)
      foreign_version = ActsAsTenant.with_tenant(other_org) do
        doc = create(:document, project: create(:project, organisation: other_org), organisation: other_org)
        create(:document_version, document: doc, organisation: other_org)
      end
      sign_in member

      download(id: foreign_version.id)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for an unknown kind' do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      sign_in member

      download(kind: 'totally_unknown')

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a tampered / non-existent record id' do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      sign_in member

      download(id: SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 when the record exists but has no attached file' do
      # Access present, but no blob: nothing to serve => 404 (instead of 500 from
      # send_blob_stream(nil)). Catches the mutation that removes the attached? guard.
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      version.document_version_file.purge
      sign_in member

      download

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a document_version when the member has tickets_access but NOT documents_access' do
      # Symmetric wrong-area guard: document_version must authorize through DocumentPolicy
      # (documents_access). If it ever resolved via the tickets area, this would return 200.
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only', documents_access: 'no_access')
      sign_in member

      download

      expect(response).to have_http_status(:not_found)
    end
  end

  # Whitelist integrity (positive iteration over the constant): every registered kind must
  # resolve a real model that actually exposes its attachment accessor, and a callable
  # authorize_target. Catches a typo'd model/attachment when a kind is added or renamed —
  # which a per-kind request test would only catch if someone remembered to add it.
  describe 'DOWNLOADABLES whitelist' do
    Organisations::FileDownloadsController::DOWNLOADABLES.each do |kind, config|
      it "#{kind}: resolves its model class, exposes the attachment accessor, and has a callable authorize_target" do
        model = config.fetch(:model).call
        expect(model).to be < ApplicationRecord
        expect(model.new).to respond_to(config.fetch(:attachment))
        expect(config.fetch(:authorize_target)).to respond_to(:call)
      end
    end
  end

  # Pins the relink: the old download action must NOT point to the unprotected
  # rails_blob_path route anymore, but to the authorized proxy.
  describe 'GET documents#download (relink to proxy)' do
    it 'redirects an authorized download to the proxy path, not the raw blob route' do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      sign_in member

      get download_organisation_project_document_path(organisation, project_a, document, version_id: version.id)

      expect(response).to redirect_to(
        organisation_file_download_path(organisation_id: organisation.id, kind: 'document_version', id: version.id)
      )
      expect(response.location).not_to include('/rails/active_storage/')
    end
  end

  # doc/dateivorschau_plan.md, D5: a viewer in a frame asks for byte ranges.
  # Bytes, not pages: a valid range answers 206, Content-Range and exactly those
  # bytes; the full answer announces Accept-Ranges; an invalid range 416; a
  # foreign version 404 like every other request.
  describe 'byte ranges' do
    before do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only')
      sign_in member
    end

    it 'announces ranges on the full answer' do
      download
      expect(response).to have_http_status(:ok)
      expect(response.headers['Accept-Ranges']).to eq('bytes')
    end

    it 'answers a valid range with 206, Content-Range and exactly those bytes' do
      get organisation_file_download_path(organisation_id: organisation.id, kind: 'document_version', id: version.id),
          headers: { 'Range' => 'bytes=0-4' }

      expect(response).to have_http_status(:partial_content)
      expect(response.headers['Content-Range']).to eq("bytes 0-4/#{version.document_version_file.byte_size}")
      expect(response.body).to eq('dummy')
    end

    it 'answers an invalid range with 416' do
      get organisation_file_download_path(organisation_id: organisation.id, kind: 'document_version', id: version.id),
          headers: { 'Range' => 'bytes=999999-1000000' }

      expect(response).to have_http_status(:range_not_satisfiable)
    end

    it 'answers a version whose file is gone with 404, range or not' do
      blob = version.document_version_file.blob
      blob.service.delete(blob.key)

      get organisation_file_download_path(organisation_id: organisation.id, kind: 'document_version', id: version.id),
          headers: { 'Range' => 'bytes=0-4' }
      expect(response).to have_http_status(:not_found)

      download
      expect(response).to have_http_status(:not_found)
    end

    it 'answers a foreign version with 404, range or not' do
      other_org = create(:organisation)
      other_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      other_document = ActsAsTenant.with_tenant(other_org) { create(:document, project: other_project, organisation: other_org) }
      foreign = ActsAsTenant.with_tenant(other_org) { create(:document_version, document: other_document, organisation: other_org) }

      get organisation_file_download_path(organisation_id: organisation.id, kind: 'document_version', id: foreign.id),
          headers: { 'Range' => 'bytes=0-4' }

      expect(response).to have_http_status(:not_found)
    end
  end
end
