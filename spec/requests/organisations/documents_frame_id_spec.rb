# frozen_string_literal: true

require 'rails_helper'

# Regression: In the knowledge view, the document detail is loaded into the frame on a
# row click via JS through documents#show?frame=content&frame_id=knowledge_display_frame.
# The action did wrap the content in the correct <turbo-frame>, but did NOT pass the
# frame_id through to the partial -> the edit pencil defaulted to
# 'document_display_frame'. Clicking it -> Turbo does not find the frame on the knowledge
# page -> "Content missing". This spec pins that the frame_id is consistently passed
# through all the way to the pencil, including the default for the standard documents view.
RSpec.describe 'Organisations documents#show frame_id threading', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  let(:document) do
    ActsAsTenant.with_tenant(organisation) do
      doc = create(:document, project: project, organisation: organisation)
      version = create(:document_version, document: doc, organisation: organisation, title: 'Aktuelle Version')
      doc.update!(current_version: version)
      doc
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

  def get_content_frame(frame_id: nil)
    params = { frame: 'content' }
    params[:frame_id] = frame_id if frame_id
    sign_in member_with('read_write')
    get organisation_project_document_path(organisation, project, document), params: params
  end

  describe 'GET show with frame=content&frame_id=knowledge_display_frame' do
    before { get_content_frame(frame_id: 'knowledge_display_frame') }

    it 'wraps the content in the requested turbo-frame' do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-frame id="knowledge_display_frame"')
    end

    it 'renders the edit pencil targeting the SAME frame (not the document default)' do
      edit_path = edit_organisation_project_document_path(organisation, project, document)
      # The pencil link carries the knowledge view's frame_id through …
      expect(response.body).to match(/#{Regexp.escape(edit_path)}[^"']*frame_id=knowledge_display_frame/)
      # … and targets the same frame via data-turbo-frame.
      expect(response.body).to include('data-turbo-frame="knowledge_display_frame"')
      # The wrong default must NOT appear (that was the bug).
      expect(response.body).not_to include('frame_id=document_display_frame')
      expect(response.body).not_to include('data-turbo-frame="document_display_frame"')
    end
  end

  describe 'GET show with frame=content in turbo_stream format (Cancel-Pfad-Robustheit)' do
    # Regression: the cancel link previously called show?frame=content&format=turbo_stream
    # -> the partial lookup searched for _document_content_for_frame as .turbo_stream
    # -> "Missing partial" (500). The content is always HTML (formats: [:html]).
    it 'rendert den Content als HTML statt Missing partial' do
      sign_in member_with('read_write')
      get organisation_project_document_path(organisation, project, document, format: :turbo_stream),
          params: { frame: 'content', frame_id: 'knowledge_display_frame' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-frame id="knowledge_display_frame"')
      expect(response.body).not_to match(/Missing partial/i)
    end
  end

  describe 'GET edit — der Abbrechen-Link' do
    before do
      sign_in member_with('read_write')
      get edit_organisation_project_document_path(organisation, project, document),
          params: { frame: 'content', frame_id: 'knowledge_display_frame' }
    end

    it 'zielt zurueck auf den Content im richtigen Frame, OHNE turbo_stream-Format' do
      show_path = organisation_project_document_path(organisation, project, document)
      # Cancel -> show?frame=content&frame_id=knowledge_display_frame (HTML frame nav)
      expect(response.body).to match(/#{Regexp.escape(show_path)}\?[^"']*frame_id=knowledge_display_frame/)
      expect(response.body).to include('data-turbo-frame="knowledge_display_frame"')
      # The old, faulty turbo_stream cancel must NOT be there anymore.
      expect(response.body).not_to match(/#{Regexp.escape(show_path)}[^"']*format=turbo_stream/)
      expect(response.body).not_to include("#{show_path}.turbo_stream")
    end
  end

  describe 'PATCH update with frame=content&frame_id (Save zurueck in den richtigen Frame)' do
    # Regression: respond_after_successfull_save wrote the content hardcoded to
    # document_display_frame + updated documents_list_frame/document rows -> in the
    # knowledge view these targets do not exist -> the save visibly went nowhere.
    it 'aktualisiert den Wissen-Frame per turbo_stream, nicht document_display_frame' do
      sign_in member_with('read_write')
      patch organisation_project_document_path(organisation, project, document),
            params: { frame: 'content', frame_id: 'knowledge_display_frame', document: { title: 'Neuer Titel' } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('target="knowledge_display_frame"')
      # The documents-view targets must NOT appear in the knowledge response.
      expect(response.body).not_to include('document_display_frame')
      expect(response.body).not_to include('documents_list_frame')
    end

    it 'streamt keine Alt-Listen-Ziele mehr, sondern die Knowledge-Zeile (M5: Standard-Dokumente-Ansicht abgeschafft)' do
      sign_in member_with('read_write')
      patch organisation_project_document_path(organisation, project, document),
            params: { frame: 'content', frame_id: 'document_display_frame', document: { title: 'Neuer Titel 2' } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      # frame_id is still passed through …
      expect(response.body).to include('target="document_display_frame"')
      # … but list updates now only target the knowledge row
      expect(response.body).not_to include('documents_list_frame')
      expect(response.body).to include('data-item-id')
    end
  end

  describe 'GET show with frame=content but WITHOUT frame_id' do
    before { get_content_frame(frame_id: nil) }

    it 'defaults the wrapper and the pencil to knowledge_display_frame (M5: einzige Detail-Anzeige)' do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-frame id="knowledge_display_frame"')
      expect(response.body).to include('data-turbo-frame="knowledge_display_frame"')
      expect(response.body).not_to include('document_display_frame')
    end
  end

  # The former "Versions-Loeschmenue (Dropdown-Mechanik)" spec was removed together with the
  # top delete dropdown: document deletion now lives in the bottom danger zone and per-version
  # deletion happens inline — both covered by the permission spec below.

  describe 'Versionsliste — Uploader-Anzeige + Listen-Layout (statt Tabelle)' do
    it 'zeigt den Namen des Uploaders, wenn einer gesetzt ist' do
      uploader = ActsAsTenant.with_tenant(organisation) do
        u = create(:user, first_name: 'Mara', last_name: 'Upload')
        create(:document_version, document: document, organisation: organisation, title: 'Mit Uploader', user: u)
        u
      end

      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(uploader.display_name)
    end

    it 'zeigt "ohne Angabe" fuer Bestands-Versionen ohne Uploader' do
      # The document's existing version (see the `document` let) has no user.
      # The wording is the row's own key (S2 of doc/dokumentansicht_plan.md).
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.documents.version_row.uploaded_by_unknown'))
    end

    it 'markiert die aktuelle Version mit dem "aktuell"-Chip' do
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-version-current')
      expect(response.body).to include(I18n.t('views.organisations.documents.version_row.current'))
    end

    it 'rendert die Versionen als Liste, nicht mehr als Tabelle' do
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      # The versions container is the new list (divide-y), and the fragile
      # table markup with its wrapping headers is gone.
      expect(response.body).to match(/id="[^"]*_document_versions"[^>]*class="[^"]*divide-y/)
      expect(response.body).not_to include('<table')
      expect(response.body).not_to include('Hochgeladen von')
    end
  end

  describe 'Versionsdatei oeffnen + herunterladen' do
    # Helper: all <a> open-tags whose attributes mention a version file proxy URL.
    def version_file_link_tags
      response.body.scan(/<a\b[^>]*>/).select { |tag| tag.include?('files/document_version') }
    end

    it 'oeffnet die Versionsdatei im neuen Tab (target=_blank, Turbo-Bypass)' do
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      open_links = version_file_link_tags.select { |tag| tag.include?('target="_blank"') }
      # Without target=_blank Turbo Drive swallows the click and the PDF never opens —
      # this guards exactly that regression.
      expect(open_links).not_to be_empty
      expect(open_links.join).to include('rel="noopener"')
    end

    it 'bietet pro Version einen expliziten Download (download-Attribut erzwingt Speichern)' do
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      download_links = version_file_link_tags.select { |tag| tag.include?('download') }
      expect(download_links).not_to be_empty
    end

    it 'entfernt den dokumentweiten "Datei herunterladen"-Button (Download lebt jetzt pro Version)' do
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Datei herunterladen')
      # No document-level /download link anymore (must not match /download_plain_text,
      # which stays as the per-version text export).
      doc_level_download = response.body.scan(/<a\b[^>]*>/).select { |tag| tag =~ %r{/documents/[^"]*/download["?]} }
      expect(doc_level_download).to be_empty
    end
  end

  describe 'Loesch-Aktionen + Berechtigung (im "···" des Kopfes, read-only ausgeblendet)' do
    it 'gibt Schreib-Usern das Loeschen des Dokuments im Kopf und pro Version, ohne Gefahrenzone' do
      get_content_frame(frame_id: 'knowledge_display_frame') # signs in as read_write

      expect(response).to have_http_status(:ok)
      # The document's delete lives in the head's "···" (S3 of doc/dokumentansicht_plan.md) ...
      head = Capybara.string(response.body).find('[data-lane-head]', visible: :all)
      expect(head).to have_css('a[data-turbo-method="delete"][data-turbo-confirm]',
                               text: I18n.t('views.organisations.documents.document_content_for_frame.delete_document'), visible: :all)
      expect(response.body).not_to include('Gefahrenzone')
      # ... per-version delete exists inline ...
      expect(response.body).to match(%r{/documents/[^"]*/destroy_version})
      # ... and the redundant "delete this version" dropdown option is gone.
      expect(response.body).not_to include('Diese Version löschen')
    end

    it 'blendet fuer read-only User jede Loesch-Aktion aus (Zeile UND Dokument), Download bleibt' do
      sign_in member_with('read_only')
      get organisation_project_document_path(organisation, project, document),
          params: { frame: 'content', frame_id: 'knowledge_display_frame' }

      expect(response).to have_http_status(:ok)
      # Read-only must see no delete affordance at all.
      expect(response.body).not_to match(%r{/documents/[^"]*/destroy_version})
      expect(response.body).not_to include('data-turbo-method="delete"')
      expect(response.body).not_to include(I18n.t('views.organisations.documents.document_content_for_frame.delete_document'))
      # Reading/downloading the file stays available (that is read access).
      expect(response.body).to include('files/document_version')
    end
  end

  describe 'Beschreibung nur bei vorhandenem Text' do
    # The writer's description is a paragraph without a label (S3 of
    # doc/dokumentansicht_plan.md), marked data-document-description.
    it 'zeigt den Beschreibungsabsatz, wenn das Dokument eine Beschreibung hat' do
      # The document's current version carries a description (factory default).
      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-document-description')
    end

    it 'laesst den Absatz komplett weg, wenn keine Beschreibung vorhanden ist' do
      ActsAsTenant.with_tenant(organisation) do
        blank = create(:document_version, document: document, organisation: organisation,
                                          title: 'Ohne Beschreibung', description: nil)
        document.update_columns(current_version_id: blank.id)
      end

      get_content_frame(frame_id: 'knowledge_display_frame')

      expect(response).to have_http_status(:ok)
      # No bare paragraph (it used to render a "Beschreibung:" label with nothing after it).
      expect(response.body).not_to include('data-document-description')
    end
  end
end
