# frozen_string_literal: true

require 'rails_helper'

# What: the three document forms after S4 of doc/dokumentansicht_plan.md (the
#   designer's 43a): the new version in the document frame, the first upload
#   in the knowledge lane, the standalone new page.
# Type: request spec.
# Why: the file comes first as a zone that is a label around the real input,
#   the title field is the zone's target, the button is off until a file is
#   chosen; the new version names the number it becomes and the version that
#   stays; the summary switch binds create_summary (D2, it used to post a name
#   nothing read); the locked sentence appears in exactly one state (D3).
RSpec.describe 'Document forms', type: :request do
  # An organisation whose lanes can deliver (the R4 spec's setup); the locked
  # state is reached by refusing one lane below.
  let(:organisation) do
    create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef',
                          embedding_access_token: 'sk-test-1234567890abcdef')
  end
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

  def page = Capybara.string(response.body)
  def frame_path(document) = organisation_project_knowledge_index_path(organisation, project, document_id: document.id)
  def zone_form = page.find('form[data-controller="upload-zone"]', visible: :all)
  def locked_sentence = I18n.t('views.organisations.documents.ai_locked_state.sentence')

  def document_with(titles)
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      versions = titles.each_with_index.map do |title, i|
        create(:document_version, document: doc, organisation: organisation, number: i + 1, title: title,
                                  created_at: (titles.size - i).days.ago)
      end
      doc.update!(current_version: versions.last)
      doc
    end
  end

  def refuse_only(feature_key)
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
      .with(feature_key, anything)
      .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential, required_provider: 'openai'))
  end

  def get_new_frame
    get new_organisation_project_document_path(organisation, project, frame: 'content'), headers: { 'Turbo-Frame' => 'knowledge_display_frame' }
  end

  def get_new_page = get new_organisation_project_document_path(organisation, project)

  describe 'the drop zone, on all three surfaces' do
    it 'puts the file first as a label around the real input, the title as its target, the button off' do
      document = document_with(%w[Einzig])
      [-> { get frame_path(document) }, -> { get_new_frame }, -> { get_new_page }].each do |request|
        request.call
        form = zone_form
        expect(form).to have_css('label[data-upload-zone-target="zone"] input[type="file"][data-upload-zone-target="input"].sr-only', visible: :all)
        expect(form).to have_css('input[type="text"][data-upload-zone-target="title"]', visible: :all)
        expect(form).to have_css('button[type="submit"][disabled][data-upload-zone-target="submit"]', visible: :all)
        expect(form).to have_no_css('input[data-direct-upload-url]', visible: :all)
        expect(form).to have_text(I18n.t('views.organisations.documents.upload_zone.prompt'))
      end
    end
  end

  describe 'the new version' do
    it 'names the number it becomes and the version that stays' do
      document = document_with(%w[Alt Neu])
      get frame_path(document)

      expect(page.find('[data-version-form-heading]', visible: :all).text).to eq(I18n.t('views.organisations.documents.version_form.heading', label: 'v3'))
      expect(page.find('[data-version-form-keeps]', visible: :all).text).to eq(I18n.t('views.organisations.documents.version_form.keeps_previous', label: 'v2'))
    end

    it 'binds the summary switch to create_summary and folds with a text action' do
      document = document_with(%w[Einzig])
      get frame_path(document)

      form = zone_form
      expect(form).to have_css('input[type="checkbox"][name="document_version[create_summary]"]', visible: :all)
      expect(response.body).not_to include('process_with_ai')
      expect(form).to have_css('button[type="button"][data-action="toggle#toggle"]', text: I18n.t('views.organisations.documents.version_form.cancel'), visible: :all)
    end

    it 'carries the summary wish into the version (D2)' do
      document = document_with(%w[Einzig])
      upload = Rack::Test::UploadedFile.new(StringIO.new('content'), 'text/plain', true, original_filename: 'v2.txt')

      post create_version_organisation_project_document_path(organisation, project, document),
           params: { document_version: { title: 'V2', document_version_file: upload, create_summary: '1' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      newest = ActsAsTenant.with_tenant(organisation) { document.document_versions.order(:created_at).last }
      expect(newest.title).to eq('V2')
      expect(newest.create_summary).to be(true)
    end
  end

  describe 'the locked state (D3)' do
    it 'says the one sentence, with the way to the settings, while AI is on and the embedding lane refuses' do
      refuse_only(:content_indexing)
      document = document_with(%w[Einzig])
      get frame_path(document)

      locked = page.find('[data-ai-locked-state]', visible: :all)
      expect(locked.text).to include(locked_sentence)
      # _top: the link leaves the lane's frame, the settings page has none (review of #784).
      expect(locked).to have_css("a[href='#{organisation_ai_settings_path(organisation)}'][data-turbo-frame='_top']", visible: :all)
    end

    it 'reaches the first upload too, in the lane and on the page' do
      refuse_only(:content_indexing)
      get_new_frame
      expect(response.body).to include(locked_sentence)
      get_new_page
      expect(response.body).to include(locked_sentence)
    end

    it 'says nothing while the lane can deliver' do
      document = document_with(%w[Einzig])
      get frame_path(document)

      expect(page).to have_no_css('[data-ai-locked-state]', visible: :all)
      expect(response.body).not_to include(locked_sentence)
    end

    context 'while AI is off' do
      let(:organisation) { create(:organisation, ai_enabled: false) }

      it 'says nothing, even with a refused lane' do
        refuse_only(:content_indexing)
        document = document_with(%w[Einzig])
        get frame_path(document)

        expect(response.body).not_to include(locked_sentence)
      end
    end
  end
end
