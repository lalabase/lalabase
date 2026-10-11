# frozen_string_literal: true

require 'rails_helper'

# What: the version list in the document frame (doc/dokumentansicht_plan.md, S2;
#   the designer's 42a) and the "als aktuell setzen" action.
# Type: request spec on the knowledge lane's document root and on the new route.
# Why: the list lost its shell, its thumbnail and its three framed buttons; what
#   is left has to carry the meaning by itself: the quiet chip on the current
#   row only, "als aktuell setzen" on the old rows only and only for writers,
#   the consequence of the last delete in the item and its confirm, the date in
#   the reader's own format, and no blue or green as a state colour (green is
#   navigation here); of the indexing words only the failure.
RSpec.describe 'Document version list', type: :request do
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

  # Every record is created BEFORE the first request of an example: the Rack
  # middleware resets the tenant afterwards and a later create raises NoTenantSet.
  def page = Capybara.string(response.body)
  def row(version) = page.find("##{dom_id(version)}_document_versions", visible: :all)
  def frame_path(document) = organisation_project_knowledge_index_path(organisation, project, document_id: document.id)
  def current_version_id_of(document) = ActsAsTenant.with_tenant(organisation) { document.reload.current_version_id }

  # Versions oldest first, numbered from 1, the last one current.
  def document_with(titles, **attrs)
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      versions = titles.each_with_index.map do |title, i|
        create(:document_version, { document: doc, organisation: organisation, number: i + 1, title: title,
                                    created_at: (titles.size - i).days.ago }.merge(attrs))
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

  describe 'the list' do
    it 'has no shell around the rows and no blue or green as a state colour' do
      document, = document_with(%w[Alt Neu])
      get frame_path(document)

      list = page.find("##{dom_id(document)}_document_versions", visible: :all)
      expect(list[:class]).not_to include('border-ink')
      expect(list[:class]).not_to include('rounded-lg')
      html = list.native.to_html
      expect(html).not_to include('bg-blue-100')
      expect(html).not_to match(/\b(bg|text)-green-/)
      expect(html).not_to include('<img')
    end

    it 'marks the current version with the quiet chip, and only that one' do
      document, (old, current) = document_with(%w[Alt Neu])
      get frame_path(document)

      expect(row(current)).to have_css('[data-version-current]', visible: :all)
      expect(row(old)).to have_no_css('[data-version-current]', visible: :all)
    end

    it "writes the date in the reader's own format, in mono" do
      user.update!(preferences: { 'date_display' => { 'global_format' => 'custom', 'custom_format' => '%Y/%m/%d %H|%M' } })
      document, (version,) = document_with(%w[Einzig])
      get frame_path(document)

      date = row(version).find('[data-version-date]', visible: :all)
      expect(date.text).to eq(version.created_at.strftime('%Y/%m/%d %H|%M'))
      expect(date[:class]).to include('font-mono')
    end

    it 'writes the size without decimals and "ohne Angabe" for an unrecorded uploader' do
      big = Rack::Test::UploadedFile.new(StringIO.new('x' * 1_500_000), 'text/plain', true, original_filename: 'gross.txt')
      document, (version,) = document_with(%w[Einzig], document_version_file: big)
      get frame_path(document)

      text = row(version).text
      expect(text).to include(ActiveSupport::NumberHelper.number_to_human_size(1_500_000, precision: 0))
      expect(text).not_to match(/\d[.,]\d+ MB/)
      expect(text).to include(I18n.t('views.organisations.documents.version_row.uploaded_by_unknown'))
    end
  end

  describe '"als aktuell setzen"' do
    it 'is offered on the old versions only' do
      document, (old, current) = document_with(%w[Alt Neu])
      get frame_path(document)

      expect(row(old)).to have_css('a[data-version-set-current][data-turbo-method="patch"]', visible: :all)
      expect(row(current)).to have_no_css('[data-version-set-current]', visible: :all)
    end

    it 'is not offered to a reader, nor is the delete item' do
      document, (old,) = document_with(%w[Alt Neu])
      sign_in reader
      get frame_path(document)

      expect(row(old)).to have_no_css('[data-version-set-current]', visible: :all)
      expect(row(old)).to have_no_css('a[data-turbo-method="delete"]', visible: :all)
    end

    it 'names the title change in the confirm when the titles differ, and asks nothing when they are the same' do
      document, (old,) = document_with(%w[Alt Neu])
      same, (older,) = document_with(%w[Gleich Gleich])

      get frame_path(document)
      confirm = row(old).find('[data-version-set-current]', visible: :all)['data-turbo-confirm']
      expect(confirm).to include('Alt').and include('Neu')

      get frame_path(same)
      expect(row(older).find('[data-version-set-current]', visible: :all)['data-turbo-confirm']).to be_nil
    end

    it 'moves the pointer and re-renders the frame and the knowledge row' do
      document, (old, current) = document_with(%w[Alt Neu])

      patch set_current_version_organisation_project_document_path(organisation, project, document, version_id: old.id),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(current_version_id_of(document)).to eq(old.id)
      expect(response.body).to include('action="update" target="knowledge_display_frame"')
      # Rails writes the selector's quotes as &#39; inside the attribute.
      expect(response.body).to match(/targets="tr\[data-item-id=(&#39;|')#{document.id}/)

      get frame_path(document)
      expect(row(old)).to have_css('[data-version-current]', visible: :all)
      expect(row(current)).to have_no_css('[data-version-current]', visible: :all)
      expect(page.find("tr[data-item-id='#{document.id}']", visible: :all).text).to include('Alt')
    end

    it "answers a version that is not the document's with a redirect and no change" do
      document, (_old, current) = document_with(%w[Alt Neu])
      _stranger, (foreign,) = document_with(%w[Fremd])

      patch set_current_version_organisation_project_document_path(organisation, project, document, version_id: foreign.id)

      expect(response).to have_http_status(:found)
      expect(current_version_id_of(document)).to eq(current.id)
    end
  end

  describe 'the "···"' do
    it 'lists the text version only when there is one' do
      document, (plain, bare) = document_with(%w[Text Ohne])
      DocumentVersion.unscoped.where(id: plain.id).update_all(plain_text_version: 'hello')
      get frame_path(document)

      text_path = download_plain_text_organisation_project_document_path(organisation, project, document, version_id: plain.id)
      expect(row(plain)).to have_css("a[href='#{text_path}']", visible: :all)
      expect(row(bare)).to have_no_css("a[href*='download_plain_text']", visible: :all)
    end

    it 'names the consequence when the last version is deleted' do
      document, (only,) = document_with(%w[Einzig])
      two, (old,) = document_with(%w[Alt Neu])

      get frame_path(document)
      item = row(only).find('a[data-turbo-method="delete"]', visible: :all)
      expect(item.text).to include(I18n.t('views.organisations.documents.version_row.delete_last'))
      expect(item['data-turbo-confirm']).to eq(I18n.t('views.confirm.delete_last_document_version'))

      get frame_path(two)
      item = row(old).find('a[data-turbo-method="delete"]', visible: :all)
      expect(item.text).to include(I18n.t('views.organisations.documents.version_row.delete'))
      expect(item['data-turbo-confirm']).to eq(I18n.t('views.confirm.delete_document_version'))
    end
  end

  describe 'the indexing words' do
    def state_of(version) = row(version).all('[data-index-state]', visible: :all).map { |s| s['data-index-state'] }

    def flag(version, value)
      DocumentVersion.unscoped.where(id: version.id).update_all(create_embeddings: true, embeddings_creation_flag: value)
    end

    # The failure is the one state (the note's rule since #778). A pending word
    # was tried and dropped in the review of #781: the flag alone cannot tell a
    # running job from a file that never gets one (an image, a ZIP, an unreadable
    # PDF, the stock before the AI switch), so "wird verarbeitet" would have
    # stood forever on all of them.
    it 'writes the failure in red and nothing for a version that is done or still running' do
      document, (pending, failed, done) = document_with(%w[A B C])
      flag(pending, nil)
      flag(failed, false)
      flag(done, true)
      get frame_path(document)

      expect(state_of(failed)).to eq(%w[failed])
      expect(row(failed).find('[data-index-state]', visible: :all)[:class]).to include('text-red')
      expect(state_of(pending)).to be_empty
      expect(state_of(done)).to be_empty
      expect(row(pending).text).not_to include('verarbeitet')
    end
  end
end
