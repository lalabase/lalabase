# frozen_string_literal: true

require 'rails_helper'

# What:  Creating a note / uploading a document from the Knowledge view via a Turbo
#        form submission must end on the Knowledge page showing the new item, and a
#        validation failure must put the form (with the error) back into the frame.
# Type:  Request spec (regression guard, 2026-08-22).
# Why:   Turbo submits forms with `Accept: text/vnd.turbo-stream.html, text/html, ...`
#        and fetch follows the 302 from #create with the SAME header. knowledge#index
#        used to answer such a request with a turbo_stream (a `replace` of the list),
#        which Turbo processed INSTEAD of performing the page visit: the form stayed
#        in the detail frame and every further click on "Speichern" created the same
#        note again. The failure branch was worse: `render :new` rendered the legacy
#        full-page template, which crashed (500) on the unsaved note's nil created_at.
#
#        The guard simulates the browser faithfully: the POST carries the Turbo
#        submit header and the redirect is followed with the same header (the Rails
#        test helper follow_redirect! drops request headers, fetch does not).
RSpec.describe 'Knowledge: create note/document via Turbo form submission', type: :request do
  # Exactly what Turbo sends for a non-GET form submission.
  let(:turbo_submit_headers) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' } }

  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, user: u, project: project, notes_access: 'read_write', documents_access: 'read_write')
    end
    u
  end
  let(:knowledge_path) { organisation_project_knowledge_index_path(organisation, project) }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in member
  end
  after { ActsAsTenant.current_tenant = nil }

  # The Rack middleware resets the tenant after each request.
  def note_count = ActsAsTenant.with_tenant(organisation) { project.notes.count }
  def document_count = ActsAsTenant.with_tenant(organisation) { project.documents.count }

  # Follows the redirect the way fetch does: same Accept header as the submission.
  def follow_redirect_like_turbo!
    expect(response).to have_http_status(:found)
    get response.location, headers: turbo_submit_headers
  end

  describe 'knowledge#index (redirect target)' do
    it 'answers the page as HTML even when the Accept header prefers turbo-stream' do
      get knowledge_path, headers: turbo_submit_headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include('id="knowledge_display_frame"')
    end
  end

  describe 'notes#create' do
    let(:create_path) { organisation_project_notes_path(organisation, project) }

    it 'lands on the Knowledge page showing the new note (no stream on the redirect chain)' do
      expect do
        post create_path,
             params: { frame_id: 'knowledge_display_frame',
                       note: { title: 'Turbo-Notiz', content: '<p>Inhalt</p>', lock_version: '' } },
             headers: turbo_submit_headers
      end.to change { note_count }.by(1)

      follow_redirect_like_turbo!

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      note = ActsAsTenant.with_tenant(organisation) { project.notes.find_by!(title: 'Turbo-Notiz') }
      expect(response.body).to include("data-item-id=\"#{note.id}\"")
      expect(response.body).not_to include('<turbo-stream')
    end

    it 'puts the form with the validation error back into the frame when the content is empty' do
      expect do
        post create_path,
             params: { frame_id: 'knowledge_display_frame',
                       note: { title: 'Ohne Inhalt', content: '<p><br></p>', lock_version: '' } },
             headers: turbo_submit_headers
      end.not_to(change { note_count })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('target="knowledge_display_frame"')
      expect(response.body).to include('name="note[title]"')
      expect(response.body).to include("#{Note.human_attribute_name(:content)} #{I18n.t('errors.messages.blank')}")
    end

    it 'falls back to the Knowledge page with an alert for a plain HTML submission' do
      post create_path,
           params: { note: { title: 'Ohne Inhalt', content: '', lock_version: '' } },
           headers: { 'Accept' => 'text/html' }

      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, type: 'all'))
      expect(flash[:alert]).to include(Note.human_attribute_name(:content))
    end
  end

  describe 'documents#create' do
    let(:create_path) { organisation_project_documents_path(organisation, project) }
    let(:upload) do
      Rack::Test::UploadedFile.new(StringIO.new('hello'), 'text/plain', true, original_filename: 'hello.txt')
    end

    it 'lands on the Knowledge page showing the new document' do
      expect do
        post create_path,
             params: { frame_id: 'knowledge_display_frame',
                       document: { document_versions_attributes: { '0' => { title: 'Turbo-Datei', document_version_file: upload } } } },
             headers: turbo_submit_headers
      end.to change { document_count }.by(1)

      follow_redirect_like_turbo!

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      document = ActsAsTenant.with_tenant(organisation) { project.documents.order(:created_at).last }
      expect(response.body).to include("data-item-id=\"#{document.id}\"")
    end

    it 'puts the form with the error back into the frame when no file was selected' do
      expect do
        post create_path,
             params: { frame_id: 'knowledge_display_frame',
                       document: { document_versions_attributes: { '0' => { title: 'Ohne Datei' } } } },
             headers: turbo_submit_headers
      end.not_to(change { document_count })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('target="knowledge_display_frame"')
      expect(response.body).to include('document_version_file')
      expect(response.body).to include(I18n.t('flash.documents.no_file_selected'))
    end
  end
end
