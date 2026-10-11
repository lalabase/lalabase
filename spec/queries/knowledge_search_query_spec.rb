# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KnowledgeSearchQuery do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:creator_b) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: creator_b, organisation: organisation, role: admin_role, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def create_note(attrs = {})
    create(:note, { project: project, organisation: organisation, creator: user }.merge(attrs))
  end

  def create_document_with_version(title: 'Test Document', plain_text_version: nil, creator: user, **attrs)
    Prosopite.pause do
      doc = create(:document, { project: project, organisation: organisation, creator: creator }.merge(attrs))
      version = create(:document_version,
                       document: doc,
                       organisation: organisation,
                       title: title,
                       plain_text_version: plain_text_version)
      doc.update!(current_version: version)
      doc
    end
  end

  def tag_item(item, tag_name)
    tag = Tag.find_by(name: tag_name, organisation_id: organisation.id) ||
          create(:tag, name: tag_name, organisation: organisation)
    create(:tagging, tag: tag, taggable: item)
  end

  def run(params = {}, **opts)
    described_class.new(
      project,
      ActiveSupport::HashWithIndifferentAccess.new(params),
      {
        current_user: user,
        accessible_type_keys: opts.fetch(:accessible_type_keys, %w[note document]),
        active_smart_folder: opts[:active_smart_folder],
        filter_params: opts.fetch(:filter_params, {}),
        operator_params: opts.fetch(:operator_params, {}),
        per_page: opts.fetch(:per_page, 10)
      }
    ).call
  end

  describe 'union and default ordering' do
    it 'merges notes and documents ordered by created_at desc' do
      old_note = create_note(title: 'Old Note', created_at: 3.days.ago)
      newer_doc = create_document_with_version(title: 'Newer Doc', created_at: 1.day.ago)
      mid_note = create_note(title: 'Mid Note', created_at: 2.days.ago)

      result = run

      expect(result.items).to eq([newer_doc, mid_note, old_note])
      expect(result.pagy.count).to eq(3)
    end

    it 'excludes documents without a current_version' do
      visible = create_document_with_version(title: 'Visible')
      hidden = create(:document, project: project, organisation: organisation, creator: user)

      items = run.items

      expect(items).to include(visible)
      expect(items).not_to include(hidden)
    end
  end

  describe 'pagination (DB-side)' do
    before do
      5.times { |i| create_note(title: "Note #{i}", created_at: i.days.ago) }
    end

    it 'paginates with a DB limit and exposes the full count' do
      result = run({ page: 1 }, per_page: 2)

      expect(result.items.size).to eq(2)
      expect(result.pagy.count).to eq(5)
      expect(result.pagy.pages).to eq(3)
    end

    it 'returns the next slice on page 2' do
      page1 = run({ page: 1 }, per_page: 2).items
      page2 = run({ page: 2 }, per_page: 2).items

      expect(page1 & page2).to be_empty
      expect(page2.size).to eq(2)
    end

    it 'treats page 0 as page 1' do
      expect(run({ page: 0 }, per_page: 2).pagy.page).to eq(1)
    end

    it 'clamps a page beyond the last page to the last page' do
      result = run({ page: 99 }, per_page: 2)

      expect(result.pagy.page).to eq(3)
      expect(result.items).not_to be_empty
    end
  end

  describe 'type filter' do
    let!(:note) { create_note(title: 'A Note') }
    let!(:document) { create_document_with_version(title: 'A Doc') }

    it 'returns only notes for type=note' do
      expect(run({ type: 'note' }).items).to eq([note])
    end

    it 'returns only documents for type=document' do
      expect(run({ type: 'document' }).items).to eq([document])
    end

    it 'ignores unknown type values' do
      expect(run({ type: 'bogus' }).items).to contain_exactly(note, document)
    end
  end

  describe 'access arms' do
    let!(:note) { create_note(title: 'A Note') }
    let!(:document) { create_document_with_version(title: 'A Doc') }

    it 'skips arms the user cannot access' do
      result = run({}, accessible_type_keys: %w[note])

      expect(result.items).to eq([note])
    end

    it 'returns an empty result without any accessible type' do
      result = run({}, accessible_type_keys: [])

      expect(result.items).to be_empty
      expect(result.pagy.count).to eq(0)
    end

    it 'does not leak an inaccessible type through the type param' do
      result = run({ type: 'document' }, accessible_type_keys: %w[note])

      expect(result.items).to be_empty
    end
  end

  describe 'search' do
    let!(:note) { create_note(title: 'Alpha Anleitung', content: 'Inhalt') }
    # plain_text_version is extracted from content (before_save callback)
    let!(:body_note) { create_note(title: 'Sonstiges', content: 'verstecktes alpha im Text') }
    let!(:document) { create_document_with_version(title: 'Alpha Datei') }
    let!(:body_document) { create_document_with_version(title: 'Anhang', plain_text_version: 'alpha im Dokument') }
    let!(:unrelated) { create_note(title: 'Beta') }

    it 'finds title and content matches across both types (content mode)' do
      items = run({ search: 'alpha' }).items

      expect(items).to contain_exactly(note, body_note, document, body_document)
    end

    it 'only searches titles in title_only mode' do
      items = run({ search: 'alpha', search_mode: 'title_only' }).items

      expect(items).to contain_exactly(note, document)
    end

    it 'strips surrounding whitespace' do
      items = run({ search: '  alpha  ', search_mode: 'title_only' }).items

      expect(items).to contain_exactly(note, document)
    end
  end

  describe 'ad-hoc filters' do
    let!(:bug_note) { create_note(title: 'Bug Note') }
    let!(:bug_doc) { create_document_with_version(title: 'Bug Doc') }
    let!(:clean_note) { create_note(title: 'Clean Note') }

    before do
      tag_item(bug_note, 'bug')
      tag_item(bug_doc, 'bug')
      tag_item(bug_note, 'urgent')
    end

    it 'filters by tag across both types (OR)' do
      items = run({}, filter_params: { 'tag' => ['bug'] }).items

      expect(items).to contain_exactly(bug_note, bug_doc)
    end

    it 'requires all tags with the AND operator' do
      items = run({}, filter_params: { 'tag' => %w[bug urgent] }, operator_params: { 'tag' => 'and' }).items

      expect(items).to eq([bug_note])
    end

    it 'excludes tagged items with the NOT operator' do
      items = run({}, filter_params: { 'tag' => ['bug'] }, operator_params: { 'tag' => 'not' }).items

      expect(items).to eq([clean_note])
    end

    it 'filters by creator' do
      other_note = create_note(title: 'From B', creator: creator_b)

      items = run({}, filter_params: { 'creator' => [creator_b.id] }).items

      expect(items).to eq([other_note])
    end

    it 'filters by created_at preset' do
      old_note = create_note(title: 'Ancient', created_at: 2.months.ago)

      items = run({}, filter_params: { 'created_at' => ['last_7_days'] }).items

      expect(items).to include(bug_note, bug_doc, clean_note)
      expect(items).not_to include(old_note)
    end

    it 'ignores ticket-only filter fields instead of failing' do
      items = run({}, filter_params: { 'assignee' => [user.id], 'status' => ['Offen'] }).items

      expect(items).to contain_exactly(bug_note, bug_doc, clean_note)
    end
  end

  describe 'smart folder narrowing' do
    let!(:special_note) { create_note(title: 'Spezial Note') }
    let!(:plain_note) { create_note(title: 'Plain Note') }
    let!(:special_doc) { create_document_with_version(title: 'Spezial Doc') }

    before do
      tag_item(special_note, 'spezial')
      tag_item(special_doc, 'spezial')
    end

    def build_folder(target:, tag_value: 'spezial')
      folder = create(:smart_folder, organisation: organisation, project: project,
                                     user: user, target_object_type: target)
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group,
                                 field: 'tag', operator: 'has', value: tag_value)
      folder
    end

    # No more Prosopite.pause needed: the TagFilter memoizes the tag lookup
    # on the rule (cached_tag_ids) — these tests watch over the memoization
    # (without it Prosopite reports the uniform lookups per model arm).
    it 'limits a Note folder to matching notes and acts as type filter' do
      result = run({}, active_smart_folder: build_folder(target: 'Note'))

      expect(result.items).to eq([special_note])
    end

    it 'filters both types for an All folder' do
      result = run({}, active_smart_folder: build_folder(target: 'All'))

      expect(result.items).to contain_exactly(special_note, special_doc)
    end

    it 'keeps All views out of meetings even with a shared creator rule and never loads them for tickets' do
      create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: true)
      folder = build_folder(target: 'All')
      folder.smart_folder_rule_groups.first.smart_folder_rules.create!(field: 'creator', operator: 'equals', value: user.id, position: 2)
      sql = []
      subscriber = ->(*event) { sql << event.last[:sql] }
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        result = run({}, active_smart_folder: folder, accessible_type_keys: %w[note document meeting])
        expect(result.items).to contain_exactly(special_note, special_doc)
        expect(SmartFolderQueryBuilder.new(folder, user).build_results_query.grep(Meeting)).to be_empty
        TicketSearchQuery.new(project, { smart_folder_id: folder.id }, current_user: user,
                                                                       policy_scope: SmartFolderPolicy::Scope.new(user, SmartFolder).resolve).call.load
      end
      expect(sql.grep(/FROM "meetings"/i)).to be_empty
    end

    it 'returns no knowledge items for a Meeting folder, including released meetings' do
      create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: true)
      folder = create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: 'Meeting')
      result = run({}, active_smart_folder: folder, accessible_type_keys: %w[note document meeting])

      expect(result.items).to be_empty
      expect(result.pagy.count).to eq(0)
    end

    it 'returns nothing when the folder matches no items' do
      result = run({}, active_smart_folder: build_folder(target: 'All', tag_value: 'nonexistent-tag'))

      expect(result.items).to be_empty
    end

    it 'filters by a creator rule (creator-Regel-Feld via AssociationFilter)' do
      foreign_note = create_note(title: 'Fremde Note', creator: creator_b)
      folder = create(:smart_folder, organisation: organisation, project: project,
                                     user: user, target_object_type: 'Note')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group,
                                 field: 'creator', operator: 'equals', value: creator_b.id)

      result = run({}, active_smart_folder: folder)

      expect(result.items).to eq([foreign_note])
    end

    it 'returns nothing for a folder the reader may not see' do
      reader = create(:user)
      create(:membership, user: reader, organisation: organisation, role: create(:role, organisation: organisation), active: true)
      create(:project_permission, project: project, user: reader, notes_access: 'read_only')
      hidden = create(:smart_folder, organisation: organisation, project: project, user: creator_b, target_object_type: 'Note', is_public: false)
      hidden.smart_folder_rule_groups.create!(position: 1)
            .smart_folder_rules.create!(field: 'title', operator: 'contains', value: 'Note', position: 1)
      result = described_class.new(
        project, ActiveSupport::HashWithIndifferentAccess.new,
        { current_user: reader, accessible_type_keys: %w[note], active_smart_folder: hidden,
          filter_params: {}, operator_params: {}, per_page: 10 }
      ).call
      expect(result.items).to be_empty
    end
  end

  describe 'sorting' do
    let!(:b_note) { create_note(title: 'B-Titel', created_at: 2.days.ago) }
    let!(:a_doc) { create_document_with_version(title: 'A-Titel', created_at: 3.days.ago) }
    let!(:c_note) { create_note(title: 'C-Titel', created_at: 1.day.ago) }

    it 'sorts by title when requested' do
      items = run({ sort: { column: 'title', direction: 'asc' } }).items

      expect(items).to eq([a_doc, b_note, c_note])
    end

    it 'falls back to created_at desc for non-whitelisted sort columns' do
      items = run({ sort: { column: 'plain_text_version; DROP TABLE notes', direction: 'asc' } }).items

      expect(items).to eq([c_note, b_note, a_doc])
    end
  end

  describe 'meetings belong to their own list' do
    let(:keys) { %w[note document meeting] }

    before do
      create(:meeting, project: project, organisation: organisation, creator: user,
                       title: 'Roadmap Sync', notes: 'Preisgestaltung', create_embeddings: true)
      create(:meeting, project: project, organisation: organisation, creator: user,
                       title: 'Private Sync', create_embeddings: false)
    end

    it 'lists only notes and documents, regardless of the meeting search release' do
      note = create_note(title: 'Eine Notiz')
      document = create_document_with_version(title: 'Ein Dokument')

      result = run({ type: 'all' }, accessible_type_keys: keys)
      expect(result.items).to contain_exactly(note, document)
      expect(result.pagy.count).to eq(2)
    end

    it 'ignores stale meeting type filters without returning meetings' do
      note = create_note
      expect(run({ type: 'meeting' }, accessible_type_keys: keys).items).to eq([note])
      expect(run({}, accessible_type_keys: keys, filter_params: { 'type' => ['meeting'] }).items).to eq([note])
    end

    it 'does not find released meetings by title or content' do
      expect(run({ search: 'roadmap', search_mode: 'title_only' }, accessible_type_keys: keys).items).to be_empty
      expect(run({ search: 'preisgestaltung', search_mode: 'content' }, accessible_type_keys: keys).items).to be_empty
    end
  end
end
