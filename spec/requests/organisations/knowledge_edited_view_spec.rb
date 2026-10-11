# frozen_string_literal: true

require 'rails_helper'

# The edited view (doc/filterleiste_s1_s4_plan.md, S3a). When the address
# carries a dissolvable saved view AND edits to it, the list applies the
# effective conditions (saved, overridden per category by the address, minus
# filter_drop[]) instead of the folder query. Before, folder and edits were
# intersected: an added value changed nothing and a dropped category stayed,
# while the bar showed both as done. The same rule is pinned client-side in
# spec/javascript/lib/filter_bar/change_set.test.js.
RSpec.describe 'Organisations::Knowledge edited view', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:knowledge_path) { organisation_project_knowledge_index_path(organisation, project) }

  let!(:bug_note) { create_note(title: 'Bug Note') }
  let!(:ui_note) { create_note(title: 'UI Note') }
  let!(:plain_note) { create_note(title: 'Plain Note') }

  # Saved view: tag has any of bug, ui  (dissolves to tag: [bug, ui], "or")
  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, name: 'Tagged', organisation: organisation, project: project,
                                     user: user, target_object_type: 'Note')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_any_of', value: 'bug,ui')
      folder
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    tag_item(bug_note, 'bug')
    tag_item(ui_note, 'ui')
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def create_note(attrs = {})
    ActsAsTenant.with_tenant(organisation) do
      create(:note, { project: project, organisation: organisation, creator: user }.merge(attrs))
    end
  end

  def tag_item(item, tag_name)
    tag = Tag.find_by(name: tag_name, organisation_id: organisation.id) ||
          create(:tag, name: tag_name, organisation: organisation)
    create(:tagging, tag: tag, taggable: item)
  end

  def rows
    response.body.scan(/data-item-id="([^"]+)"/).flatten
  end

  it 'applies the saved view as it is without edits' do
    get knowledge_path, params: { smart_folder_id: folder.id }

    expect(rows).to contain_exactly(bug_note.id, ui_note.id)
  end

  it 'narrows when the address keeps fewer of the saved values' do
    get knowledge_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] } }

    expect(rows).to contain_exactly(bug_note.id)
  end

  it 'widens when the address adds a value to the saved category (an intersection could not)' do
    tag_item(plain_note, 'docs')
    get knowledge_path, params: { smart_folder_id: folder.id, filter: { tag: %w[bug ui docs] } }

    expect(rows).to contain_exactly(bug_note.id, ui_note.id, plain_note.id)
  end

  it 'drops a saved category the reader emptied (filter_drop[])' do
    get knowledge_path, params: { smart_folder_id: folder.id, filter_drop: ['tag'] }

    expect(rows).to contain_exactly(bug_note.id, ui_note.id, plain_note.id)
  end

  it 'takes the operator of an edited category from the address, not from the view' do
    get knowledge_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] }, filter_op: { tag: 'not' } }

    expect(rows).to contain_exactly(ui_note.id, plain_note.id)
  end

  it 'hands the bar the address as typed, not the effective set' do
    get knowledge_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] }, filter_drop: ['creator'] }

    bar = response.body[/data-filter-bar-active-filters-value="([^"]*)"/, 1]
    expect(CGI.unescapeHTML(bar)).to eq({ 'tag' => ['bug'] }.to_json)
    expect(response.body).to include('data-filter-bar-dropped-value="[&quot;creator&quot;]"')
  end

  it 'keeps the intersection for a view with rules the bar cannot dissolve' do
    ActsAsTenant.with_tenant(organisation) do
      group = folder.smart_folder_rule_groups.first
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Note')
    end

    # The folder (bug or ui, title contains Note) stays; the added tag cannot widen it.
    tag_item(plain_note, 'docs')
    get knowledge_path, params: { smart_folder_id: folder.id, filter: { tag: %w[bug ui docs] } }

    expect(rows).to contain_exactly(bug_note.id, ui_note.id)
  end

  # The bar leaves "or" out of the address. A saved NOT flipped back to OR
  # therefore arrives as filter[tag][]=bug with no filter_op, and that must
  # read as "or", not as the saved operator.
  it 'reads a missing filter_op on an edited category as or' do
    ActsAsTenant.with_tenant(organisation) do
      group = folder.smart_folder_rule_groups.first
      SmartFolderRule.where(smart_folder_rule_group: group).destroy_all
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'not_has', value: 'bug')
    end

    get knowledge_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] } }

    expect(rows).to contain_exactly(bug_note.id)
  end

  # An operator without values is no edit: the bar never writes one, and the
  # pills would show the saved operator while the list applied the other.
  it 'ignores an operator without values, as the bar does' do
    get knowledge_path, params: { smart_folder_id: folder.id, filter_op: { tag: 'not' } }

    expect(rows).to contain_exactly(bug_note.id, ui_note.id)
  end

  # The folder's target type is not a condition the dissolver can express. It
  # has to survive the edit: a Note view stays a Note view, on type=all too.
  it 'keeps the type scope of the edited view' do
    document = ActsAsTenant.with_tenant(organisation) do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      version = create(:document_version, document: doc, organisation: organisation, title: 'Bug Doc')
      doc.update!(current_version: version)
      doc
    end
    tag_item(document, 'bug')

    get knowledge_path, params: { smart_folder_id: folder.id, filter_drop: ['tag'] }

    expect(rows).to contain_exactly(bug_note.id, ui_note.id, plain_note.id)
    expect(rows).not_to include(document.id)
  end

  # The built-in type views (S7) are saved views in code: ?type=note carries
  # the condition Typ: Notiz, and the same edits apply to it as to a folder.
  describe 'a built-in type view' do
    let!(:document) do
      ActsAsTenant.with_tenant(organisation) do
        Prosopite.pause do
          doc = create(:document, project: project, organisation: organisation, creator: user)
          version = create(:document_version, document: doc, organisation: organisation, title: 'Bug Doc')
          doc.update!(current_version: version)
          doc
        end
      end
    end

    it 'shows only its type as saved' do
      get knowledge_path, params: { type: 'note' }

      expect(rows).to contain_exactly(bug_note.id, ui_note.id, plain_note.id)
    end

    it 'widens when the reader adds a second type to the condition' do
      get knowledge_path, params: { type: 'note', filter: { type: %w[note document] } }

      expect(rows).to contain_exactly(bug_note.id, ui_note.id, plain_note.id, document.id)
    end

    it 'shows every type when the reader drops the type condition' do
      get knowledge_path, params: { type: 'note', filter_drop: ['type'] }

      expect(rows).to contain_exactly(bug_note.id, ui_note.id, plain_note.id, document.id)
    end

    it 'narrows further with a condition added on top' do
      get knowledge_path, params: { type: 'note', filter: { tag: ['bug'] } }

      expect(rows).to contain_exactly(bug_note.id)
    end
  end
end
