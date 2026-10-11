# frozen_string_literal: true

require 'rails_helper'

# What:  The two seams by which a KNOWLEDGE page reaches the assistant panel
#        (doc/assistent_wissen_kontext_plan.md, step 3), the twins of the ticket
#        page's (ticket_assistant_seams_spec): the button in the lane head that
#        SETS a reference on click, and the marker by which the page NAMES its
#        object so the panel can offer it without a click.
# Type:  Request spec.
# Why:   Neither is visible from its own markup, and the knowledge object has
#        THREE roots (the note, the document, the document's preview) plus the
#        forms and the placeholder that must carry none: an unsaved draft is
#        nothing the assistant can read, and a marker on the empty lane would
#        offer an object that is not there.
RSpec.describe 'Knowledge page assistant seams', type: :request do
  let(:assistant_enabled) { true }

  let(:organisation) do
    create(:organisation, assistant_enabled: assistant_enabled, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end

  let(:role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:admin_role, organisation: organisation)
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      role
    end
  end

  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:frame) { 'knowledge_display_frame' }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def knowledge_path(**params) = organisation_project_knowledge_index_path(organisation, project, **params)

  def note
    @note ||= create(:note, project: project, organisation: organisation, creator: user, title: 'Einarbeitung')
  end

  def document
    @document ||= Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      version = create(:document_version, document: doc, organisation: organisation, title: 'Angebot 2026')
      doc.update!(current_version: version)
      doc
    end
  end

  def html = Nokogiri::HTML.fragment(response.body)
  def buttons = html.css('[data-lane-assistant]')
  def button = buttons.first
  def markers = html.css('[data-assistant-context]')
  def marker = markers.first

  shared_examples 'a page that names its object and offers the button' do |type:, label:|
    it "names the #{type.downcase} and renders the button once, from the registry" do
      expect(response).to have_http_status(:ok)
      expect(markers.size).to eq(1)
      expect(marker['data-assistant-context']).to eq(record.id)
      expect(marker['data-assistant-context-type']).to eq(type)
      expect(marker['data-assistant-context-label']).to eq(label)

      expect(buttons.size).to eq(1)
      expect(button['data-controller']).to eq('assistant-trigger')
      expect(button['data-assistant-trigger-type-value']).to eq(type)
      expect(button['data-assistant-trigger-id-value']).to eq(record.id)
      expect(button['data-action']).to include('assistant-trigger#adopt')
      # lg only, like the ✕ beside it: below that breakpoint there is no lane.
      expect(button['class']).to include('hidden').and include('lg:flex')
    end
  end

  describe 'the note' do
    let(:record) { note }

    context 'on the page' do
      before { get knowledge_path(note_id: note.id) }

      include_examples 'a page that names its object and offers the button', type: 'Note', label: 'Einarbeitung'
    end

    context 'on the frame request' do
      before { get organisation_project_note_path(organisation, project, note, frame: 'content', frame_id: frame) }

      include_examples 'a page that names its object and offers the button', type: 'Note', label: 'Einarbeitung'
    end
  end

  describe 'the document' do
    let(:record) { document }

    context 'on the page' do
      before { get knowledge_path(document_id: document.id) }

      include_examples 'a page that names its object and offers the button', type: 'Document', label: 'Angebot 2026'
    end

    context 'on the frame request' do
      before do
        get organisation_project_document_path(organisation, project, document, frame: 'content', frame_id: frame)
      end

      include_examples 'a page that names its object and offers the button', type: 'Document', label: 'Angebot 2026'
    end

    # The third root: the preview names the DOCUMENT, whatever version it shows,
    # and the button's title says the current version is what gets read.
    context 'on the preview of a version' do
      before do
        get knowledge_path(document_id: document.id, KnowledgeFilterHelper::PREVIEW_PARAM => document.current_version.id)
      end

      include_examples 'a page that names its object and offers the button', type: 'Document', label: 'Angebot 2026'

      it 'says that the current version is what the assistant reads' do
        expect(button['title']).to eq(I18n.t('views.organisations.knowledge.lane.ask_assistant.document'))
        expect(button['title']).to include('aktuelle Version')
      end
    end

    # Review of #799: on an OLDER version the marker's LABEL says it, because
    # the offer strip and the draft pill are built from the label and never see
    # the button's tooltip. Whoever looks at v1 and takes the offer gets answers
    # about v2, and the strip has to say so before the click.
    context 'on the preview of an older version' do
      let(:older) do
        Prosopite.pause do
          create(:document_version, document: document, organisation: organisation, title: 'Angebot 2025')
        end
      end

      before do
        older
        get knowledge_path(document_id: document.id, KnowledgeFilterHelper::PREVIEW_PARAM => older.id)
      end

      it 'names the document with the current-version word in the label' do
        expect(response).to have_http_status(:ok)
        expect(marker['data-assistant-context']).to eq(document.id)
        expect(marker['data-assistant-context-label'])
          .to eq("Angebot 2026 #{I18n.t('views.organisations.documents.preview.assistant_current_version')}")
        expect(I18n.t('views.organisations.documents.preview.assistant_current_version', locale: :en, fallback: false))
          .to eq('(current version)')
      end
    end
  end

  # Both seams are gated on the assistant, together: a door to a lane that is
  # not there is what the panel's own gate exists to prevent.
  context 'with the assistant switched off for the organisation' do
    let(:assistant_enabled) { false }

    it 'renders neither the marker nor the button' do
      get knowledge_path(note_id: note.id)

      expect(response).to have_http_status(:ok)
      expect(markers).to be_empty
      expect(buttons).to be_empty
    end
  end

  # A reader may ask about what they may read: the button sits outside the
  # write-right condition, next to a head without a pencil.
  context 'for a reader without the write right' do
    let(:role) do
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation, title: 'Reader')
        create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
        role
      end
    end

    it 'offers the button without the pencil' do
      create(:project_permission, user: user, project: project, notes_access: 'read_only')

      get knowledge_path(note_id: note.id)

      expect(response).to have_http_status(:ok)
      expect(buttons.size).to eq(1)
      expect(html.css('.note-edit-button')).to be_empty
    end
  end

  describe 'what carries neither seam' do
    it 'the empty lane' do
      get knowledge_path

      expect(markers).to be_empty
      expect(buttons).to be_empty
    end

    it 'the new-note form, on the page and on the frame request' do
      get knowledge_path(new: 'note')
      expect(markers).to be_empty
      expect(buttons).to be_empty

      get new_organisation_project_note_path(organisation, project, frame: 'content', frame_id: frame),
          headers: { 'Turbo-Frame' => frame }
      expect(markers).to be_empty
      expect(buttons).to be_empty
    end

    it 'the edit form of a note' do
      get edit_organisation_project_note_path(organisation, project, note, frame_id: frame),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response.body).not_to include('data-assistant-context')
      expect(response.body).not_to include('data-lane-assistant')
    end

    it 'the new-document form and the edit form of a document' do
      # Built BEFORE the first request: the request cycle resets the tenant.
      existing = document

      get new_organisation_project_document_path(organisation, project, frame: 'content', frame_id: frame),
          headers: { 'Turbo-Frame' => frame }
      expect(markers).to be_empty
      expect(buttons).to be_empty

      get edit_organisation_project_document_path(organisation, project, existing, frame: 'content', frame_id: frame),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response.body).not_to include('data-assistant-context')
      expect(response.body).not_to include('data-lane-assistant')
    end
  end
end
