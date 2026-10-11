# frozen_string_literal: true

require 'rails_helper'

# What: the document's head and body (doc/dokumentansicht_plan.md, S3; the
#   designer's 42a).
# Type: request spec on the knowledge lane's document root.
# Why: the attribute row says type, versions, creator, date and AI status the
#   way the ticket's row does, numbers in mono, the date in the reader's format,
#   an empty value absent; the writer's description is a paragraph without a
#   label and the AI summary a quiet block with the spark, each only when
#   present; the danger zone is gone and the delete lives in the head's "···".
RSpec.describe 'Document head and body', type: :request do
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

  # Every record is created BEFORE the first request of an example: the Rack
  # middleware resets the tenant afterwards.
  def page = Capybara.string(response.body)
  def frame_path(document) = organisation_project_knowledge_index_path(organisation, project, document_id: document.id)
  def attributes = page.find('[data-document-attributes]', visible: :all)

  # Versions oldest first, numbered from 1, the last one current. file: builds
  # the upload per version: one Rack::Test::UploadedFile is consumed by its
  # first attach, a second attach of it fails the checksum.
  def document_with(titles, file: nil, **attrs)
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      versions = titles.each_with_index.map do |title, i|
        per_version = file ? { document_version_file: file.call } : {}
        create(:document_version, { document: doc, organisation: organisation, number: i + 1, title: title,
                                    created_at: (titles.size - i).days.ago }.merge(attrs, per_version))
      end
      doc.update!(current_version: versions.last)
      [doc, versions]
    end
  end

  def flag_current(document, value)
    DocumentVersion.unscoped.where(id: document.current_version_id).update_all(create_embeddings: true, embeddings_creation_flag: value)
  end

  describe 'the attribute row' do
    it "names the type from the file, counts the versions in mono, shows the creator and the date in the reader's format" do
      user.update!(preferences: { 'date_display' => { 'global_format' => 'custom', 'custom_format' => '%Y/%m/%d %H|%M' } })
      pdf = -> { Rack::Test::UploadedFile.new(StringIO.new('%PDF-1.4'), 'application/pdf', true, original_filename: 'plan.pdf') }
      document, = document_with(%w[Alt Neu], file: pdf)
      get frame_path(document)

      row = attributes
      expect(row.find('[data-document-kind]', visible: :all).text).to include(I18n.t('views.shared.file_kinds.pdf'))
      count = row.find('[data-document-version-count]', visible: :all)
      expect(count.find('.font-mono', visible: :all).text).to eq('2')
      expect(count.text).to include(I18n.t('views.organisations.documents.document_content_for_frame.versions_count', count: 2))
      expect(row.find('[data-document-creator]', visible: :all).text).to include(user.display_name(mode: User::PreferenceStore::NAME_DISPLAY_DEFAULT))
      date = row.find('[data-document-created-at]', visible: :all)
      expect(date.text).to include(document.created_at.strftime('%Y/%m/%d %H|%M'))
      expect(date[:class]).to include('font-mono')
    end

    it 'shows the tags as chips in the row, without a label' do
      document, = document_with(%w[Einzig])
      document.update!(tag_list: 'alpha, beta')
      get frame_path(document)

      expect(attributes).to have_text('alpha').and have_text('beta')
      expect(response.body).not_to include('Tags:')
    end
  end

  describe 'the AI status' do
    it 'says indexed, or failed in red' do
      indexed, = document_with(%w[A])
      failed, = document_with(%w[B])
      flag_current(indexed, true)
      flag_current(failed, false)

      get frame_path(indexed)
      expect(attributes.find('[data-document-ai-state]', visible: :all)['data-document-ai-state']).to eq('indexed')

      get frame_path(failed)
      state = attributes.find('[data-document-ai-state]', visible: :all)
      expect(state['data-document-ai-state']).to eq('failed')
      expect(state[:class]).to include('text-red')
    end

    context 'while AI is off' do
      let(:organisation) { create(:organisation, ai_enabled: false) }

      it 'says nothing while the index has not answered, but keeps the slot the broadcast fills' do
        document, = document_with(%w[A])
        flag_current(document, nil)
        get frame_path(document)

        expect(attributes).to have_no_css('[data-document-ai-state]', visible: :all)
        expect(attributes).to have_css("##{ActionView::RecordIdentifier.dom_id(document)}_ai_state", visible: :all)
      end
    end

    context 'while AI is on and the embedding lane refuses' do
      let(:organisation) { create(:organisation, ai_enabled: true) }

      it 'says not available' do
        document, = document_with(%w[A])
        flag_current(document, nil)
        get frame_path(document)

        expect(attributes.find('[data-document-ai-state]', visible: :all)['data-document-ai-state']).to eq('unavailable')
      end
    end
  end

  describe 'the two descriptions' do
    it 'writes the description as a paragraph without a label, and none without one' do
      described, = document_with(%w[A], description: 'Was drin ist')
      bare, = document_with(%w[B], description: nil)

      get frame_path(described)
      expect(page.find('[data-document-description]', visible: :all).text).to eq('Was drin ist')
      expect(response.body).not_to include('Beschreibung:')

      get frame_path(bare)
      expect(page).to have_no_css('[data-document-description]', visible: :all)
    end

    it 'shows the AI summary as a quiet block with the spark, only when there is one' do
      summarised, = document_with(%w[A], generated_summary: 'Kurz gesagt', summary_creation_flag: true)
      pending, = document_with(%w[B], generated_summary: 'Kurz gesagt', summary_creation_flag: false)

      get frame_path(summarised)
      block = page.find('[data-document-summary]', visible: :all)
      expect(block).to have_css('i.bi-stars', visible: :all)
      expect(block).to have_text(I18n.t('views.organisations.documents.document_content_for_frame.summary_heading'))
      expect(block).to have_text('Kurz gesagt')

      get frame_path(pending)
      expect(page).to have_no_css('[data-document-summary]', visible: :all)
    end
  end

  it 'has no danger zone; the delete sits in the head with its confirm' do
    document, = document_with(%w[A])
    get frame_path(document)

    expect(response.body).not_to include('Gefahrenzone')
    expect(response.body).not_to include('Danger zone')
    head = page.find('.document-content [data-lane-head]', visible: :all)
    item = head.find('a[data-turbo-method="delete"]', visible: :all)
    expect(item.text).to include(I18n.t('views.organisations.documents.document_content_for_frame.delete_document'))
    expect(item['data-turbo-confirm']).to eq(I18n.t('views.confirm.delete_all_document_versions'))
    expect(head).to have_css('a[href*="/edit"]', text: I18n.t('views.organisations.documents.document_content_for_frame.rename'), visible: :all)
  end
end
