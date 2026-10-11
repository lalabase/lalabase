# frozen_string_literal: true

require 'rails_helper'

# Filter pipeline of the knowledge list (M2 of the knowledge filter rework):
# ad-hoc filter URLs (filter[...]/filter_op[...]) and smart-folder filtering
# run via KnowledgeSearchQuery, analogous to the tickets page.
RSpec.describe 'Organisations::Knowledge Filter', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:knowledge_path) { organisation_project_knowledge_index_path(organisation, project) }

  let!(:bug_note) { create_note(title: 'Bug Note') }
  let!(:clean_note) { create_note(title: 'Clean Note') }
  let!(:bug_document) { create_document_with_version(title: 'Bug Doc') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    tag_item(bug_note, 'bug')
    tag_item(bug_document, 'bug')
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def create_note(attrs = {})
    ActsAsTenant.with_tenant(organisation) do
      create(:note, { project: project, organisation: organisation, creator: user }.merge(attrs))
    end
  end

  def create_document_with_version(title:)
    ActsAsTenant.with_tenant(organisation) do
      Prosopite.pause do
        doc = create(:document, project: project, organisation: organisation, creator: user)
        version = create(:document_version, document: doc, organisation: organisation, title: title)
        doc.update!(current_version: version)
        doc
      end
    end
  end

  def tag_item(item, tag_name)
    tag = Tag.find_by(name: tag_name, organisation_id: organisation.id) ||
          create(:tag, name: tag_name, organisation: organisation)
    create(:tagging, tag: tag, taggable: item)
  end

  def expect_item_in_response(item)
    expect(response.body).to include("data-item-id=\"#{item.id}\"")
  end

  def expect_item_not_in_response(item)
    expect(response.body).not_to include("data-item-id=\"#{item.id}\"")
  end

  describe 'ad-hoc filter params' do
    it 'filters by tag across both types' do
      get knowledge_path, params: { filter: { tag: ['bug'] } }

      expect(response).to have_http_status(:ok)
      expect_item_in_response(bug_note)
      expect_item_in_response(bug_document)
      expect_item_not_in_response(clean_note)
    end

    it 'supports the NOT operator' do
      get knowledge_path, params: { filter: { tag: ['bug'] }, filter_op: { tag: 'not' } }

      expect_item_in_response(clean_note)
      expect_item_not_in_response(bug_note)
      expect_item_not_in_response(bug_document)
    end

    it 'filters by creator' do
      other_user = create(:user)
      create(:membership, user: other_user, organisation: organisation, role: admin_role, active: true)
      foreign_note = create_note(title: 'Fremde Note', creator: other_user)

      get knowledge_path, params: { filter: { creator: [other_user.id] } }

      expect_item_in_response(foreign_note)
      expect_item_not_in_response(bug_note)
    end

    it 'ignores ticket-only filter fields instead of erroring' do
      get knowledge_path, params: { filter: { assignee: [user.id] } }

      expect(response).to have_http_status(:ok)
      expect_item_in_response(bug_note)
      expect_item_in_response(clean_note)
    end
  end

  describe 'the type as a condition (S7)' do
    it 'narrows to one type' do
      get knowledge_path, params: { filter: { type: ['note'] } }

      expect(response).to have_http_status(:ok)
      expect_item_in_response(bug_note)
      expect_item_in_response(clean_note)
      expect_item_not_in_response(bug_document)
    end

    it 'takes two types' do
      get knowledge_path, params: { filter: { type: %w[note document] } }

      expect_item_in_response(bug_note)
      expect_item_in_response(bug_document)
    end

    it 'combines with another condition' do
      get knowledge_path, params: { filter: { type: ['document'], tag: ['bug'] } }

      expect_item_in_response(bug_document)
      expect_item_not_in_response(bug_note)
    end

    it 'ignores an unknown type like an unknown ?type= (nothing is narrowed)' do
      get knowledge_path, params: { filter: { type: ['bogus'] } }

      expect(response).to have_http_status(:ok)
      expect_item_in_response(bug_note)
      expect_item_in_response(bug_document)
    end

    # The condition is a trust boundary: the readable types are intersected
    # FIRST (KnowledgeSearchQuery#type_keys_to_query), then the condition.
    # Swapping those two lines would stay green without this.
    context 'when the reader may read notes only' do
      let(:reader) { create(:user) }
      let(:notes_reader_role) do
        role = create(:role, organisation: organisation, title: 'notes_reader')
        create(:project_read_permission, role: role, area: 'notes')
        role
      end

      before do
        create(:membership, user: reader, organisation: organisation, role: notes_reader_role, active: true)
        sign_in reader
      end

      # Nothing readable matches a type the reader may not read: an empty
      # list, never a document.
      it 'shows no document for a type condition the reader may not read' do
        get knowledge_path, params: { filter: { type: ['document'] } }

        expect(response).to have_http_status(:ok)
        expect_item_not_in_response(bug_document)
        expect(response.body).not_to include('data-item-id=')
      end

      it 'ignores it on an edited built-in view too (the built-in type steps aside, the access does not)' do
        get knowledge_path, params: { type: 'note', filter: { type: %w[note document] } }

        expect_item_in_response(bug_note)
        expect_item_not_in_response(bug_document)
      end
    end
  end

  describe 'smart folder filtering' do
    let(:note_folder) do
      folder = create(:smart_folder, organisation: organisation, project: project,
                                     user: user, target_object_type: 'Note')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group,
                                 field: 'tag', operator: 'has', value: 'bug')
      folder
    end

    it 'narrows the list to folder matches and applies the folder type' do
      get knowledge_path, params: { smart_folder_id: note_folder.id }

      expect(response).to have_http_status(:ok)
      expect_item_in_response(bug_note)
      expect_item_not_in_response(clean_note)
      # Note folder acts as a type filter: documents do not appear (PE-B)
      expect_item_not_in_response(bug_document)
    end

    it 'applies the folder filter also with an explicit type param' do
      get knowledge_path, params: { smart_folder_id: note_folder.id, type: 'note' }

      expect_item_in_response(bug_note)
      expect_item_not_in_response(clean_note)
    end
  end

  # A filter edit reloads only the result frame. The page's reload marker is meant
  # for a visit of the page; inside a frame answer Turbo obeys it too and reloads
  # the whole window, which closed the open filter layer after every tick.
  describe 'the reload marker' do
    let(:marker) { '<meta name="turbo-visit-control" content="reload">' }

    it 'stands on the page' do
      get knowledge_path

      expect(response.body).to include(marker)
    end

    it 'stays out of a frame answer, which then holds the results' do
      get knowledge_path, params: { filter: { tag: ['bug'] } },
                          headers: { 'Turbo-Frame' => 'knowledge_results' }

      expect(response.body).to include('<turbo-frame id="knowledge_results"')
      expect(response.body).not_to include(marker)
    end
  end
end
