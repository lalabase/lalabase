# frozen_string_literal: true

require 'rails_helper'

# What: one version of a document in the lane (doc/dateivorschau_plan.md, S1;
#   the designer's part 3): the page state ?document_id=X&preview=V, the frame
#   road documents#preview, and the root both render.
# Type: request spec.
# Why: the four cases by content type, every file through the authorised proxy
#   and never the open blob address; the head's unconditional way back to the
#   document with the live query; the file name untruncated with the version's
#   number; a foreign or missing version answers 404 at the endpoint and the
#   document on the page; a reader may see it, a member without documents
#   access may not; the text is escaped once.
RSpec.describe 'Document preview', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  include ActionView::RecordIdentifier

  def page = Capybara.string(response.body)
  def root(version) = page.find("##{dom_id(version)}_preview", visible: :all)
  def preview_path(document, version, **extra) = organisation_project_knowledge_index_path(organisation, project, { document_id: document.id, preview: version.id }.merge(extra))
  def proxy(version) = organisation_file_download_path(organisation_id: organisation.id, kind: 'document_version', id: version.id)

  def upload(content, type, name)
    Rack::Test::UploadedFile.new(StringIO.new(content), type, true, original_filename: name)
  end

  # A document with one version per given file; the last is current.
  def document_with(files, **attrs)
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      versions = files.each_with_index.map do |(content, type, name), i|
        create(:document_version, { document: doc, organisation: organisation, number: i + 1, title: name,
                                    document_version_file: upload(content, type, name), created_at: (files.size - i).days.ago }.merge(attrs))
      end
      doc.update!(current_version: versions.last)
      [doc, versions]
    end
  end

  def reader
    u = create(:user)
    role = create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
    create(:membership, user: u, organisation: organisation, role: role, active: true)
    create(:project_permission, user: u, project: project, documents_access: 'read_only')
    u
  end

  def member_without_documents
    u = create(:user)
    role = create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
    create(:membership, user: u, organisation: organisation, role: role, active: true)
    u
  end

  describe 'the four cases' do
    it 'shows a browser image as an <img> on the proxy road, with the download standing by for a broken one' do
      document, (version,) = document_with([['\x89PNG', 'image/png', 'bild.png']])
      get preview_path(document, version)

      img = root(version).find('img[data-preview-embed-target="image"]', visible: :all)
      expect(img[:src]).to eq(proxy(version))
      expect(response.body).not_to include('rails/active_storage/blobs')
      expect(root(version)).to have_css('[data-preview-embed-target="imageFallback"][hidden] [data-preview-none]', visible: :all)
    end

    it 'sends an image the proxy forces to download to the fourth case' do
      document, (version,) = document_with([['<svg/>', 'image/svg+xml', 'logo.svg']])
      get preview_path(document, version)

      expect(root(version)['data-preview-case'] || root(version).find('[data-preview-case]', visible: :all)['data-preview-case']).to eq('none')
      expect(root(version)).to have_css('[data-preview-none]', visible: :all)
      expect(root(version)).to have_css("a[href='#{proxy(version)}'][download]", visible: :all)
    end

    it "carries the preview's own road for \"Aktualisieren\", the frame the page rendered having no src to reload" do
      document, (version,) = document_with([['x', 'text/plain', 'a.txt']])
      get organisation_project_knowledge_index_path(organisation, project, document_id: document.id, preview: version.id)

      root = page.find("##{dom_id(version)}_preview", visible: :all)
      expect(root['data-preview-embed-refresh-url-value'])
        .to eq(preview_organisation_project_document_path(organisation_id: organisation.id, project_id: project.id, id: document.id, version_id: version.id))
    end

    it 'holds the PDF frame in a template on the proxy road, without a sandbox, and the text version beside it' do
      document, (version,) = document_with([['%PDF-1.4', 'application/pdf', 'plan.pdf']], plain_text_version: 'Seite eins')
      get preview_path(document, version)

      # Nokogiri does not expose <template> children to CSS, so the frame is read
      # from the raw body: inside the template, on the proxy road, no sandbox.
      expect(root(version)).to have_css('template[data-preview-embed-target="template"]', visible: :all)
      iframe = response.body[/<template data-preview-embed-target="template">\s*(<iframe[^>]*>)/, 1]
      expect(iframe).to include(%(src="#{proxy(version)}"))
      expect(iframe).not_to include('sandbox')
      expect(iframe).to include('referrerpolicy="no-referrer"')
      expect(root(version)).to have_css('[data-preview-embed-target="mount"]', visible: :all)
      expect(root(version).find('[data-preview-embed-target="fallback"]', visible: :all)).to have_css('pre[data-preview-text]', text: 'Seite eins', visible: :all)
    end

    it 'shows the text version escaped, once' do
      document, (version,) = document_with([['x', 'text/plain', 'notiz.txt']], plain_text_version: 'a <b>bold</b> & "quoted"')
      get preview_path(document, version)

      pre = root(version).find('pre[data-preview-text]', visible: :all)
      expect(pre.text).to eq('a <b>bold</b> & "quoted"')
      expect(root(version).native.inner_html).to include('&lt;b&gt;bold&lt;/b&gt; &amp;')
    end

    it 'says the text is not available yet for an extractable file without one, with a refresh' do
      docx = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      document, (version,) = document_with([['PK', docx, 'bericht.docx']], plain_text_version: nil)
      get preview_path(document, version)

      expect(root(version)).to have_css('[data-preview-text-missing]', text: I18n.t('views.organisations.documents.preview.text_unavailable'), visible: :all)
      expect(root(version)).to have_css('button[data-action="preview-embed#refresh"]', visible: :all)
      expect(root(version)).to have_no_css('iframe', visible: :all)
    end

    it 'gives everything else one sentence and the download as the main action' do
      document, (version,) = document_with([['PK', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'zahlen.xlsx']])
      get preview_path(document, version)

      expect(root(version)).to have_css('[data-preview-none]', text: I18n.t('views.organisations.documents.preview.no_preview'), visible: :all)
      expect(root(version)).to have_css("a[href='#{proxy(version)}'][download]", visible: :all)
      expect(root(version)).to have_no_css('[data-preview-text-missing]', visible: :all)
    end
  end

  describe 'the head' do
    it 'carries the way back to the document with the live query, the number and the whole file name, and the two items' do
      document, (version,) = document_with([['%PDF-1.4', 'application/pdf', 'ein sehr langer dateiname der nicht gekuerzt werden darf.pdf']])
      get preview_path(document, version, search: 'x', type: 'document')

      head = root(version).find('[data-lane-head]', visible: :all)
      back = head.find('a[data-lane-back-to-object][data-controller="lane-link"]', visible: :all)
      query = Rack::Utils.parse_nested_query(URI.parse(back[:href]).query)
      expect(query).to include('document_id' => document.id, 'search' => 'x', 'type' => 'document')
      expect(query).not_to include('preview')
      expect(back['data-lane-link-remove-value']).to eq(%w[preview].to_json)
      expect(back['data-lane-link-url-value']).to eq(organisation_project_document_path(organisation, project, document))
      expect(back['data-lane-link-focus-value']).to eq("[data-preview-link-for='#{version.id}']")
      expect(head).to have_no_css('a[data-lane-back]', visible: :all)

      title = root(version).find('h2[data-lane-title]', visible: :all)
      expect(title.text).to include('v1').and include('ein sehr langer dateiname der nicht gekuerzt werden darf.pdf')
      expect(title[:class]).to include('break-words')

      menu = head.find('[data-dropdown-target="menu"]', visible: :all)
      expect(menu).to have_css("a[href='#{proxy(version)}'][target='_blank']", text: I18n.t('views.organisations.documents.preview.open_in_new_tab'), visible: :all)
      expect(menu).to have_css("a[href='#{proxy(version)}'][download]", text: I18n.t('views.organisations.documents.preview.download'), visible: :all)
    end

    it 'previews an old version, not the current one' do
      document, (old, _current) = document_with([['x', 'text/plain', 'alt.txt'], ['y', 'text/plain', 'neu.txt']], plain_text_version: 'alter Text')
      get preview_path(document, old)

      expect(root(old).find('h2[data-lane-title]', visible: :all).text).to include('alt.txt')
    end
  end

  describe 'the two roads' do
    it 'renders the document, not a foreign or missing version, on the page' do
      document, (mine,) = document_with([['x', 'text/plain', 'a.txt']])
      _other, (foreign,) = document_with([['y', 'text/plain', 'b.txt']])

      get preview_path(document, foreign)
      expect(page).to have_no_css('.document-preview', visible: :all)
      expect(page).to have_css('.document-content', visible: :all)

      get organisation_project_knowledge_index_path(organisation, project, document_id: document.id, preview: 'missing')
      expect(page).to have_no_css('.document-preview', visible: :all)
      expect(page).to have_css("##{dom_id(mine)}_document_versions", visible: :all)
    end

    it 'answers the frame request with the same root, and 404 for a foreign version' do
      document, (mine,) = document_with([['x', 'text/plain', 'a.txt']])
      _other, (foreign,) = document_with([['y', 'text/plain', 'b.txt']])

      get preview_organisation_project_document_path(organisation, project, document, version_id: mine.id, frame: 'content', frame_id: 'knowledge_display_frame')
      expect(response).to have_http_status(:ok)
      expect(page).to have_css("turbo-frame#knowledge_display_frame ##{dom_id(mine)}_preview", visible: :all)

      get preview_organisation_project_document_path(organisation, project, document, version_id: foreign.id, frame: 'content')
      expect(response).to have_http_status(:not_found)
    end

    it 'lands a plain request on the page state' do
      document, (mine,) = document_with([['x', 'text/plain', 'a.txt']])
      get preview_organisation_project_document_path(organisation, project, document, version_id: mine.id)

      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, document_id: document.id, preview: mine.id, type: 'all'))
    end
  end

  describe 'who may look' do
    it 'shows the preview to a reader and nothing to a member without documents access' do
      document, (version,) = document_with([['x', 'text/plain', 'a.txt']])
      readers = [reader, member_without_documents]

      sign_in readers[0]
      get preview_path(document, version)
      expect(page).to have_css('.document-preview', visible: :all)

      sign_in readers[1]
      get preview_organisation_project_document_path(organisation, project, document, version_id: version.id, frame: 'content')
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe 'the row' do
    it 'opens the preview from the file name and keeps the new tab in the "···"' do
      document, (version,) = document_with([['x', 'text/plain', 'a.txt']])
      get organisation_project_knowledge_index_path(organisation, project, document_id: document.id, search: 'x')

      link = page.find("[data-preview-link-for='#{version.id}']", visible: :all)
      expect(link['data-controller']).to eq('lane-link')
      expect(link['data-lane-link-url-value']).to eq(preview_organisation_project_document_path(organisation, project, document, version_id: version.id))
      expect(JSON.parse(link['data-lane-link-set-value'])).to eq('preview' => version.id)
      query = Rack::Utils.parse_nested_query(URI.parse(link[:href]).query)
      expect(query).to include('document_id' => document.id, 'preview' => version.id, 'search' => 'x')
      expect(link[:target]).to be_nil
      row = page.find("##{dom_id(version)}_document_versions", visible: :all)
      expect(row).to have_css("a[href='#{proxy(version)}'][target='_blank']", text: I18n.t('views.organisations.documents.version_row.open_in_new_tab'), visible: :all)
    end
  end

  describe 'the page wrapper' do
    it 'names the three parameter groups once' do
      document, = document_with([['x', 'text/plain', 'a.txt']])
      get organisation_project_knowledge_index_path(organisation, project, document_id: document.id)

      groups = JSON.parse(page.find('.labor-layout-view', visible: :all)['data-lane-params'])
      expect(groups).to eq('selection' => %w[note_id document_id], 'preview' => %w[preview], 'form' => %w[new], 'ignore' => %w[viewport])
    end

    it "carries the preview route with a placeholder for each id, the restorer's road to a preview without the document view" do
      document, (version,) = document_with([['x', 'text/plain', 'a.txt']])
      get organisation_project_knowledge_index_path(organisation, project, type: 'all')

      road = page.find('.labor-layout-view', visible: :all)['data-lane-preview-url']
      expect(road).to eq(preview_organisation_project_document_path(organisation_id: organisation.id, project_id: project.id,
                                                                    id: '__SELECTION__', version_id: '__PREVIEW__'))
      expect(road.sub('__SELECTION__', document.id).sub('__PREVIEW__', version.id))
        .to eq(preview_organisation_project_document_path(organisation_id: organisation.id, project_id: project.id, id: document.id, version_id: version.id))
    end
  end
end
