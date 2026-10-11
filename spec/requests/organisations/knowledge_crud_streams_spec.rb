# frozen_string_literal: true

require 'rails_helper'

# M5 of the knowledge filter rework: notes/documents CRUD responds to the
# knowledge view (the only remaining list) — standalone calls
# redirect, turbo streams target the knowledge row/detail frame instead
# of the deleted old frames (notes_results/documents_list_frame).
RSpec.describe 'Knowledge CRUD Streams', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:turbo_stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  let!(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation, creator: user, title: 'Alte Notiz')
    end
  end

  let!(:document) do
    ActsAsTenant.with_tenant(organisation) do
      Prosopite.pause do
        doc = create(:document, project: project, organisation: organisation, creator: user)
        version = create(:document_version, document: doc, organisation: organisation, title: 'Alte Datei')
        doc.update!(current_version: version)
        doc
      end
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  # The turbo-stream targets attribute HTML-escapes the apostrophes of the CSS selector
  def row_targets_selector(item)
    "tr[data-item-id=&#39;#{item.id}&#39;]"
  end

  describe 'notes#show (Standalone)' do
    it 'redirects to the knowledge view with the note selected' do
      get organisation_project_note_path(organisation, project, note)

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')
      )
    end

    it 'still renders the detail content for frame requests' do
      get organisation_project_note_path(organisation, project, note,
                                         frame: 'content', frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('turbo-frame id="knowledge_display_frame"')
      expect(response.body).to include('Alte Notiz')
    end
  end

  describe 'notes#update (Turbo Stream)' do
    it 'replaces the knowledge row and updates the detail frame' do
      patch organisation_project_note_path(organisation, project, note),
            params: { note: { title: 'Neuer Titel', content: 'Inhalt' }, frame_id: 'knowledge_display_frame' },
            headers: turbo_stream_headers

      expect(response.body).to include(row_targets_selector(note))
      expect(response.body).to include('knowledge_display_frame')
      expect(response.body).to include('Neuer Titel')
      expect(response.body).not_to include('tr[data-note-id=')
    end
  end

  describe 'notes#destroy (Turbo Stream)' do
    it 'removes the knowledge row and clears the detail frame' do
      delete organisation_project_note_path(organisation, project, note),
             params: { frame_id: 'knowledge_display_frame' },
             headers: turbo_stream_headers

      expect(response.body).to include(row_targets_selector(note))
      expect(response.body).to include('action="remove"')
      expect(response.body).to include('knowledge_display_frame')
      expect(ActsAsTenant.with_tenant(organisation) { Note.exists?(note.id) }).to be(false)
    end
  end

  describe 'documents#update (Turbo Stream)' do
    it 'replaces the knowledge row' do
      patch organisation_project_document_path(organisation, project, document),
            params: { document: { title: 'Neuer Dateititel' },
                      frame: 'content', frame_id: 'knowledge_display_frame' },
            headers: turbo_stream_headers

      expect(response.body).to include(row_targets_selector(document))
      expect(response.body).not_to include('documents_list_frame')
    end
  end

  describe 'documents#destroy (Turbo Stream)' do
    it 'removes the knowledge row and clears the detail frame' do
      delete organisation_project_document_path(organisation, project, document),
             params: { frame_id: 'knowledge_display_frame' },
             headers: turbo_stream_headers

      expect(response.body).to include(row_targets_selector(document))
      expect(response.body).to include('action="remove"')
      expect(response.body).to include('knowledge_display_frame')
    end
  end

  describe 'notes#index / documents#index (Standalone und Frame)' do
    it 'always redirects notes index to knowledge' do
      get organisation_project_notes_path(organisation, project), headers: { 'Turbo-Frame' => 'notes_results' }

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, type: 'note')
      )
    end

    it 'always redirects documents index to knowledge' do
      get organisation_project_documents_path(organisation, project), headers: { 'Turbo-Frame' => 'documents_list_frame' }

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, type: 'document')
      )
    end
  end
end
