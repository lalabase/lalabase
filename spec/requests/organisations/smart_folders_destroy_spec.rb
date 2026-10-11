# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the DELETE #destroy Turbo-Stream response.
#
# Bug (2026-07-14): deleting a saved filter from the edit modal (tickets filter
# bar) removed the record but left the modal open. Root cause: #destroy answered
# format.turbo_stream with only `flash.now[:notice] = ...` and NO template, so
# Rails tried to implicitly render the non-existent destroy.turbo_stream.erb ->
# ActionView::MissingTemplate (500). The destroy had already committed, so a full
# reload showed the filter gone, but the Turbo request errored and the #modal
# frame never closed.
#
# Contract pinned here: a Turbo-Stream DELETE must return 200 and a stream that
# (a) removes the #modal frame and (b) navigates back to the correct list.
RSpec.describe 'Organisations::SmartFolders DELETE #destroy', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Ticket')
    end
  end

  def delete_folder(params = {}, headers: {})
    delete organisation_smart_folder_path(organisation, folder), params: params, headers: headers
  end

  # Turbo submits link/form DELETEs with the turbo-stream MIME first in Accept.
  let(:turbo_stream_headers) do
    { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' }
  end

  describe 'Turbo-Stream request (the modal path)' do
    it 'destroys the folder' do
      folder
      delete_folder({ return_to: 'tickets' }, headers: turbo_stream_headers)

      # acts_as_tenant clears the current tenant after the request, so read unscoped.
      expect(SmartFolder.unscoped.exists?(folder.id)).to be(false)
    end

    it 'returns 200 with a turbo-stream body (no MissingTemplate 500)' do
      delete_folder({ return_to: 'tickets' }, headers: turbo_stream_headers)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
    end

    it 'closes the #modal frame in the stream response' do
      delete_folder({ return_to: 'tickets' }, headers: turbo_stream_headers)

      expect(response.body).to include("getElementById('modal')")
    end

    it 'navigates back to the project tickets page for return_to=tickets' do
      delete_folder({ return_to: 'tickets' }, headers: turbo_stream_headers)

      expect(response.body).to include(
        organisation_project_tickets_path(organisation_id: organisation.id, project_id: project.id)
      )
    end

    it 'navigates back to the folder list without return_to' do
      delete_folder({}, headers: turbo_stream_headers)

      expect(response.body).to include(
        organisation_smart_folders_path(organisation_id: organisation.id)
      )
    end
  end

  describe 'HTML request (non-Turbo fallback)' do
    it 'redirects to the tickets page for return_to=tickets' do
      delete_folder({ return_to: 'tickets' })

      expect(response).to redirect_to(
        organisation_project_tickets_path(organisation_id: organisation.id, project_id: project.id)
      )
    end

    it 'redirects to the folder list without return_to' do
      delete_folder({})

      expect(response).to redirect_to(organisation_smart_folders_path(organisation_id: organisation.id))
    end
  end
end
