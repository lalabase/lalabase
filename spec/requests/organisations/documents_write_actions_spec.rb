# frozen_string_literal: true

require 'rails_helper'

# Behaviour of the write actions that were moved onto the Actor seam
# (update / destroy / destroy_version). The controller keeps only auth, params
# and rendering; these specs pin that the Turbo-stream and HTML responses stay
# identical to before the refactor — plus the two intended deltas: D6 (a blank
# title now surfaces an error instead of a silent fake-success) and F2 (a foreign
# version_id redirects with an alert instead of a 404).
RSpec.describe 'Organisations documents write actions (Actor seam)', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  # A document with exactly one current version (single attachment → no bounded
  # purge fanout, so Prosopite stays quiet on the delete path).
  let(:document) do
    ActsAsTenant.with_tenant(organisation) do
      doc = create(:document, project: project, organisation: organisation)
      version = create(:document_version, document: doc, organisation: organisation, title: 'Aktuell')
      doc.update!(current_version: version)
      doc
    end
  end

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  def member_with_write
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, user: u, project: project, documents_access: 'read_write')
    end
    u
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def document_count
    ActsAsTenant.with_tenant(organisation) { Document.where(id: document.id).count }
  end

  describe 'PATCH update' do
    it 'updates title and description on the current version (Turbo)' do
      document
      sign_in member_with_write

      patch organisation_project_document_path(organisation, project, document),
            params: { frame_id: 'knowledge_display_frame',
                      document: { title: 'Neuer Titel', description: 'Neue Beschreibung' } },
            headers: turbo_headers

      expect(response).to have_http_status(:ok)
      version = ActsAsTenant.with_tenant(organisation) { document.reload.current_version }
      expect(version.title).to eq('Neuer Titel')
      expect(version.description).to eq('Neue Beschreibung')
    end

    it 'redirects with the updated notice on the HTML path' do
      document
      sign_in member_with_write

      patch organisation_project_document_path(organisation, project, document),
            params: { document: { title: 'HTML Titel' } }

      expect(response).to have_http_status(:found)
      expect(flash[:notice]).to eq(I18n.t('flash.documents.updated'))
    end

    # D6: the version title setter used to fail silently (current_version.update),
    # so a blank title left the version unchanged BUT the controller still reported
    # success. It must now surface the validation error instead of faking success.
    it 'does not fake success for a blank title — no change, error surfaced (Turbo)' do
      document
      original_title = ActsAsTenant.with_tenant(organisation) { document.current_version.title }
      sign_in member_with_write

      patch organisation_project_document_path(organisation, project, document),
            params: { frame_id: 'knowledge_display_frame', document: { title: '' } },
            headers: turbo_headers

      # No silent success: the version title is untouched …
      expect(ActsAsTenant.with_tenant(organisation) { document.reload.current_version.title }).to eq(original_title)
      # … and the response is an error, not a 200 success stream.
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'does not fake success for a blank title on the HTML path (no updated notice)' do
      document
      sign_in member_with_write

      patch organisation_project_document_path(organisation, project, document),
            params: { document: { title: '' } }

      expect(response).not_to have_http_status(:found)
      expect(flash[:notice]).to be_blank
    end
  end

  describe 'DELETE destroy' do
    it 'destroys the document and streams row removal + empty content + flash (Turbo)' do
      document
      sign_in member_with_write

      expect do
        delete organisation_project_document_path(organisation, project, document),
               params: { frame_id: 'knowledge_display_frame' }, headers: turbo_headers
      end.to change { document_count }.by(-1)

      expect(response).to have_http_status(:ok)
      # remove_all streams a <turbo-stream action="remove"> targeting the knowledge row …
      expect(response.body).to include('action="remove"')
      expect(response.body).to include("data-item-id=&#39;#{document.id}&#39;")
      # … clears the detail frame with the empty-content partial …
      expect(response.body).to include('target="knowledge_display_frame"')
      # … and prepends the deleted flash.
      expect(response.body).to include(I18n.t('flash.documents.deleted'))
    end

    it 'redirects to the knowledge index with a notice (HTML)' do
      document
      sign_in member_with_write

      delete organisation_project_document_path(organisation, project, document)

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, type: 'document')
      )
      expect(flash[:notice]).to eq(I18n.t('flash.documents.deleted'))
    end

    it 'surfaces the raw error via delete_error_detail when the actor fails (F3)' do
      document
      sign_in member_with_write

      failure = Actors::BaseActor::Result.new(success: false, errors: ['boom'], code: :internal_error)
      allow(Actors::DestroyDocument).to receive(:call).and_return(failure)

      delete organisation_project_document_path(organisation, project, document), headers: turbo_headers

      expect(response.body).to include(I18n.t('flash.documents.delete_error_detail', error: 'boom'))
    end
  end

  describe 'DELETE destroy_version' do
    # A document with `count` versions, newest promoted to current_version. No
    # created_at backdating needed: the re-hang cases leave at most one candidate,
    # so "next-newest" is unambiguous.
    #
    # Prosopite is paused around the CREATION only: building several versions fires
    # the version's own after_update_commit Turbo broadcast (one blob/doc lookup
    # per version) — a test-setup artifact, not a production path (versions are
    # created one at a time). The delete request under test stays under scrutiny.
    def document_with_versions(count)
      Prosopite.pause
      ActsAsTenant.with_tenant(organisation) do
        doc = create(:document, project: project, organisation: organisation)
        versions = Array.new(count) do |i|
          create(:document_version, document: doc, organisation: organisation, title: "v#{i + 1}")
        end
        doc.update!(current_version: versions.last)
        [doc, versions]
      end
    ensure
      Prosopite.resume
    end

    def delete_version(doc, version_id)
      delete destroy_version_organisation_project_document_path(organisation, project, doc, version_id: version_id)
    end

    it 'outcome (a): deleting a non-current version redirects to the document with version_deleted' do
      doc, versions = document_with_versions(2)
      sign_in member_with_write

      delete_version(doc, versions.first.id) # the non-current (older) version

      expect(response).to redirect_to(organisation_project_document_path(organisation, project, doc))
      expect(flash[:notice]).to eq(I18n.t('flash.documents.version_deleted'))
      expect(ActsAsTenant.with_tenant(organisation) { DocumentVersion.where(id: versions.first.id) }).not_to exist
      expect(ActsAsTenant.with_tenant(organisation) { Document.where(id: doc.id) }).to exist
    end

    it 'outcome (b): deleting the current version re-hangs to the next and keeps the version_deleted redirect' do
      doc, versions = document_with_versions(2)
      sign_in member_with_write

      delete_version(doc, versions.last.id) # the current (newer) version

      expect(response).to redirect_to(organisation_project_document_path(organisation, project, doc))
      expect(flash[:notice]).to eq(I18n.t('flash.documents.version_deleted'))
      # current_version re-hung to the only remaining (older) version.
      expect(ActsAsTenant.with_tenant(organisation) { doc.reload.current_version }).to eq(versions.first)
    end

    it 'outcome (c): deleting the last version deletes the whole document and redirects to the index' do
      doc, versions = document_with_versions(1)
      sign_in member_with_write

      delete_version(doc, versions.first.id)

      expect(response).to redirect_to(organisation_project_documents_path(organisation, project))
      expect(flash[:notice]).to eq(I18n.t('flash.documents.all_versions_deleted'))
      expect(ActsAsTenant.with_tenant(organisation) { Document.where(id: doc.id) }).not_to exist
    end

    it 'F2: a foreign version_id redirects with an alert instead of a 404' do
      doc, = document_with_versions(1)
      sign_in member_with_write

      delete_version(doc, SecureRandom.uuid)

      expect(response).to redirect_to(organisation_project_document_path(organisation, project, doc))
      expect(flash[:alert]).to eq(I18n.t('services.actors.destroy_document_version.not_found'))
      expect(ActsAsTenant.with_tenant(organisation) { doc.reload.document_versions.count }).to eq(1)
    end
  end
end
