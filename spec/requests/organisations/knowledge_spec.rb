# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::Knowledge', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:notes_reader_role) do
    role = create(:role, organisation: organisation, title: 'notes_reader')
    create(:project_read_permission, role: role, area: 'notes')
    role
  end

  let(:documents_reader_role) do
    role = create(:role, organisation: organisation, title: 'documents_reader')
    create(:project_read_permission, role: role, area: 'documents')
    role
  end

  let(:no_access_role) do
    create(:role, organisation: organisation, title: 'no_access')
  end

  let(:knowledge_path) { organisation_project_knowledge_index_path(organisation, project) }
  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  # ── Helpers ──

  def create_note(attrs = {})
    create(:note, { project: project, organisation: organisation, creator: user }.merge(attrs))
  end

  def create_document_with_version(title: 'Test Document', plain_text_version: nil)
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      version = create(:document_version,
                       document: doc,
                       organisation: organisation,
                       title: title,
                       plain_text_version: plain_text_version)
      doc.update!(current_version: version)
      doc
    end
  end

  def sign_in_with_role(role)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  def turbo_get(path, params: {})
    get path, params: params, headers: turbo_headers
  end

  # A rendered list row carries the marker WITH a value. The bare attribute name also
  # appears in selector attributes of the page wrapper (index.html.erb), so counting the
  # bare name would count those too.
  def rendered_row_count = response.body.scan(/data-item-id="[^"]+"/).size

  # Same reason: `selected-row` also sits in the wrapper's selector attributes, so look
  # for a rendered <tr> that carries it as a class. The row's data-action contains a
  # `>` (click->list-row#click), so scan up to the class of the SAME <tr>.
  def highlighted_row_count = response.body.scan(/<tr\b(?:(?!<tr\b).)*?class="[^"]*\bselected-row\b/m).size

  def expect_item_in_response(item)
    expect(response.body).to include("data-item-id=\"#{item.id}\"")
  end

  def expect_item_not_in_response(item)
    expect(response.body).not_to include("data-item-id=\"#{item.id}\"")
  end

  # ══════════════════════════════════════════════
  # Authentication
  # ══════════════════════════════════════════════

  describe 'authentication' do
    it 'redirects unauthenticated users to sign in' do
      get knowledge_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # ══════════════════════════════════════════════
  # Authorization
  # ══════════════════════════════════════════════

  describe 'authorization' do
    context 'when user has no access to notes or documents' do
      before { sign_in_with_role(no_access_role) }

      it 'redirects to project page' do
        get knowledge_path
        expect(response).to redirect_to(organisation_project_path(organisation, project))
      end

      it 'sets a flash alert' do
        get knowledge_path
        expect(flash[:alert]).to eq(I18n.t('flash.shared.not_authorized'))
      end
    end

    context 'when user has only notes access' do
      before { sign_in_with_role(notes_reader_role) }

      it 'renders successfully' do
        turbo_get knowledge_path
        expect(response).to have_http_status(:ok)
      end
    end

    context 'when user has only documents access' do
      before { sign_in_with_role(documents_reader_role) }

      it 'renders successfully' do
        turbo_get knowledge_path
        expect(response).to have_http_status(:ok)
      end
    end

    context 'when user is admin' do
      before { sign_in_with_role(admin_role) }

      it 'renders successfully' do
        turbo_get knowledge_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Type filtering
  # ══════════════════════════════════════════════

  describe 'type filtering' do
    before { sign_in_with_role(admin_role) }

    context 'with type=all (default)' do
      let!(:note) { create_note(title: 'My Note') }
      let!(:document) { create_document_with_version(title: 'My Document') }

      it 'returns both notes and documents' do
        turbo_get knowledge_path
        expect_item_in_response(note)
        expect_item_in_response(document)
      end

      it 'renders note and document type labels' do
        turbo_get knowledge_path
        expect(response.body).to include('data-item-type="note"')
        expect(response.body).to include('data-item-type="document"')
      end
    end

    context 'with type=note' do
      let!(:note) { create_note(title: 'My Note') }
      let!(:document) { create_document_with_version(title: 'My Document') }

      it 'returns only notes' do
        turbo_get knowledge_path, params: { type: 'note' }
        expect_item_in_response(note)
        expect_item_not_in_response(document)
      end
    end

    context 'with type=document' do
      let!(:note) { create_note(title: 'My Note') }
      let!(:document) { create_document_with_version(title: 'My Document') }

      it 'returns only documents' do
        turbo_get knowledge_path, params: { type: 'document' }
        expect_item_in_response(document)
        expect_item_not_in_response(note)
      end
    end

    context 'with invalid type parameter' do
      let!(:note) { create_note(title: 'Fallback Note') }

      it 'falls back to all and still renders items' do
        turbo_get knowledge_path, params: { type: 'invalid' }
        expect(response).to have_http_status(:ok)
        expect_item_in_response(note)
      end

      it 'falls back to all for blank type' do
        turbo_get knowledge_path, params: { type: '' }
        expect(response).to have_http_status(:ok)
        expect_item_in_response(note)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Partial access — notes only
  # ══════════════════════════════════════════════

  # ══════════════════════════════════════════════
  # Built-in type views (S7): the types are tabs and a condition, not a select.
  # Tested at the rendered-page layer, per prior regression learning.
  # ══════════════════════════════════════════════

  describe 'built-in type views' do
    context 'when the user can read two knowledge types (admin)' do
      before do
        sign_in_with_role(admin_role)
        # Content is required: on first use (no knowledge at all) the whole
        # filter bar is hidden by design.
        create_note
      end

      it 'renders one tab per readable type and no type select' do
        get knowledge_path
        expect(response.body).to include('role="tab"')
        expect(response.body).to include(I18n.t('views.organisations.knowledge.index.filter_notes'))
        expect(response.body).to include(I18n.t('views.organisations.knowledge.index.filter_documents'))
        expect(response.body).not_to include('id="knowledge-type-select"')
        expect(response.body).not_to include('filter-bar#changeType')
      end

      it 'offers the type as a category of "+ Filter"' do
        get knowledge_path
        categories = JSON.parse(CGI.unescapeHTML(response.body[/data-filter-bar-categories-value="([^"]*)"/, 1]))
        type_category = categories.find { |c| c['key'] == 'type' }
        expect(type_category['label']).to eq(I18n.t('views.organisations.knowledge.index.filter_type_label'))
        # An admin reads every type; the two the spec creates content for must be among them.
        expect(type_category['options'].map { |o| o['value'] }).to include('note', 'document')
      end

      it 'makes the active type view a saved view with the condition Typ: <type>' do
        get knowledge_path, params: { type: 'note' }
        expect(response.body).to include('data-filter-bar-view-key-value="note"')
        dissolver = JSON.parse(CGI.unescapeHTML(response.body[/data-filter-bar-dissolver-value="([^"]*)"/, 1]))
        expect(dissolver['filters']).to eq('type' => ['note'])
        expect(dissolver['dissolvable']).to be true
      end

      # An address of the old bar carries both (its select kept smart_folder_id,
      # its folder pills kept ?type=). The folder is the view; the type still
      # narrows the list but marks no second tab.
      it 'lets the folder win over a ?type= next to it, one active tab' do
        folder = create(:smart_folder, name: 'Eilig', organisation: organisation, project: project, user: user, target_object_type: 'Note')

        get knowledge_path, params: { type: 'note', smart_folder_id: folder.id }

        expect(response.body.scan('aria-selected="true"').size).to eq(1)
        expect(response.body).to include('data-filter-bar-view-key-value=""')
        expect(response.body).to include(%(data-filter-bar-smart-folder-id-value="#{folder.id}"))
      end

      # The type is the folder's target, immutable (D4): a folder of one type
      # does not offer it in "+ Filter", a folder of all types does.
      it 'offers the type category on a folder of all types only' do
        note_folder = create(:smart_folder, name: 'Nur Notizen', organisation: organisation, project: project, user: user, target_object_type: 'Note')
        all_folder = create(:smart_folder, name: 'Alles', organisation: organisation, project: project, user: user, target_object_type: 'All')
        keys = -> { JSON.parse(CGI.unescapeHTML(response.body[/data-filter-bar-categories-value="([^"]*)"/, 1])).map { |c| c['key'] } }

        get knowledge_path, params: { smart_folder_id: note_folder.id }
        expect(keys.call).not_to include('type')

        get knowledge_path, params: { smart_folder_id: all_folder.id }
        expect(keys.call).to include('type')
      end
    end

    context 'when the user can read only one knowledge type (notes-only, D4)' do
      before do
        sign_in_with_role(notes_reader_role)
        create_note
      end

      it 'renders no type tab beyond the base view and no type category (no functionless control)' do
        get knowledge_path
        expect(response.body).not_to include('type=note')
        expect(response.body).not_to include('type=document')
        expect(response.body.scan('role="tab"').size).to eq(1)
        categories = JSON.parse(CGI.unescapeHTML(response.body[/data-filter-bar-categories-value="([^"]*)"/, 1]))
        expect(categories.map { |c| c['key'] }).not_to include('type')
      end

      # ?type= of the one readable type is no view either (there is no tab for
      # it), nor is a type the reader may not read (its list stays empty, see
      # "partial access" below): the base tab is the active one both times.
      it 'gives the reader no built-in view, whether the type is theirs or not' do
        get knowledge_path, params: { type: 'note' }
        expect(response.body).to include('data-filter-bar-view-key-value=""')
        expect(response.body).to include('data-filter-bar-dissolver-value="{}"')

        get knowledge_path, params: { type: 'document' }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-filter-bar-view-key-value=""')
        expect(response.body).to include('data-filter-bar-dissolver-value="{}"')
      end
    end
  end

  describe 'partial access with notes-only role' do
    before { sign_in_with_role(notes_reader_role) }

    let!(:note) { create_note(title: 'Visible Note') }
    let!(:document) { create_document_with_version(title: 'Hidden Document') }

    context 'with type=all' do
      it 'returns only notes, no documents' do
        turbo_get knowledge_path
        expect_item_in_response(note)
        expect_item_not_in_response(document)
      end
    end

    context 'with type=note' do
      it 'returns notes' do
        turbo_get knowledge_path, params: { type: 'note' }
        expect_item_in_response(note)
      end
    end

    context 'with type=document' do
      it 'returns no items' do
        turbo_get knowledge_path, params: { type: 'document' }
        expect_item_not_in_response(document)
        expect(rendered_row_count).to eq(0)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Partial access — documents only
  # ══════════════════════════════════════════════

  describe 'partial access with documents-only role' do
    before { sign_in_with_role(documents_reader_role) }

    let!(:note) { create_note(title: 'Hidden Note') }
    let!(:document) { create_document_with_version(title: 'Visible Document') }

    context 'with type=all' do
      it 'returns only documents, no notes' do
        turbo_get knowledge_path
        expect_item_in_response(document)
        expect_item_not_in_response(note)
      end
    end

    context 'with type=note' do
      it 'returns no items' do
        turbo_get knowledge_path, params: { type: 'note' }
        expect_item_not_in_response(note)
        expect(rendered_row_count).to eq(0)
      end
    end

    context 'with type=document' do
      it 'returns documents' do
        turbo_get knowledge_path, params: { type: 'document' }
        expect_item_in_response(document)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Documents without current_version
  # ══════════════════════════════════════════════

  describe 'documents without current_version' do
    before { sign_in_with_role(admin_role) }

    it 'excludes documents without a current_version' do
      orphan_doc = create(:document, project: project, organisation: organisation, creator: user)

      turbo_get knowledge_path, params: { type: 'document' }
      expect_item_not_in_response(orphan_doc)
    end
  end

  # ══════════════════════════════════════════════
  # Search
  # ══════════════════════════════════════════════

  describe 'search' do
    before { sign_in_with_role(admin_role) }

    context 'searching notes' do
      let!(:matching_note) { create_note(title: 'Ruby on Rails Guide') }
      let!(:body_match_note) do
        note = create_note(title: 'Other Note')
        note.update_column(:plain_text_version, 'This covers Rails patterns')
        note
      end
      let!(:non_matching_note) { create_note(title: 'Unrelated') }

      it 'finds notes by title (case-insensitive)' do
        turbo_get knowledge_path, params: { type: 'note', search: 'ruby' }
        expect_item_in_response(matching_note)
        expect_item_not_in_response(non_matching_note)
      end

      it 'finds notes by plain_text_version' do
        turbo_get knowledge_path, params: { type: 'note', search: 'rails patterns' }
        expect_item_in_response(body_match_note)
        expect_item_not_in_response(non_matching_note)
      end

      it 'returns empty for no matches' do
        turbo_get knowledge_path, params: { type: 'note', search: 'zzz_no_match_zzz' }
        expect(rendered_row_count).to eq(0)
      end
    end

    context 'searching documents' do
      let!(:matching_doc) { create_document_with_version(title: 'API Documentation') }
      let!(:body_match_doc) { create_document_with_version(title: 'Other Doc', plain_text_version: 'API reference guide') }
      let!(:non_matching_doc) { create_document_with_version(title: 'Unrelated') }

      it 'finds documents by version title (case-insensitive)' do
        turbo_get knowledge_path, params: { type: 'document', search: 'api' }
        expect_item_in_response(matching_doc)
        expect_item_not_in_response(non_matching_doc)
      end

      it 'finds documents by version plain_text_version' do
        turbo_get knowledge_path, params: { type: 'document', search: 'reference guide' }
        expect_item_in_response(body_match_doc)
        expect_item_not_in_response(non_matching_doc)
      end
    end

    context 'searching in all type' do
      let!(:note) { create_note(title: 'Shared Term Example') }
      let!(:document) { create_document_with_version(title: 'Shared Term Docs') }
      let!(:other_note) { create_note(title: 'Unrelated') }

      it 'searches across both notes and documents' do
        turbo_get knowledge_path, params: { type: 'all', search: 'shared term' }
        expect_item_in_response(note)
        expect_item_in_response(document)
        expect_item_not_in_response(other_note)
      end
    end

    context 'with whitespace in search term' do
      let!(:note) { create_note(title: 'Findable Note') }

      it 'strips whitespace from search term' do
        turbo_get knowledge_path, params: { type: 'note', search: '  findable  ' }
        expect_item_in_response(note)
      end
    end

    context 'with empty search term' do
      let!(:note) { create_note(title: 'Some Note') }

      it 'returns all items when search is blank' do
        turbo_get knowledge_path, params: { type: 'note', search: '' }
        expect_item_in_response(note)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Pagination
  # ══════════════════════════════════════════════

  describe 'pagination' do
    before { sign_in_with_role(admin_role) }

    context 'with type=note' do
      before do
        Prosopite.pause { 12.times { |i| create_note(title: "Note #{i}") } }
      end

      it 'paginates to requested items per page' do
        Prosopite.pause do
          turbo_get knowledge_path, params: { type: 'note', items: 5 }
        end
        item_count = rendered_row_count
        expect(item_count).to eq(5)
      end

      it 'returns second page items' do
        Prosopite.pause do
          turbo_get knowledge_path, params: { type: 'note', items: 10, page: 2 }
        end
        item_count = rendered_row_count
        expect(item_count).to eq(2)
      end

      it 'renders pagination nav when multiple pages exist' do
        Prosopite.pause do
          turbo_get knowledge_path, params: { type: 'note', items: 5 }
        end
        expect(response.body).to include('pagination')
      end
    end

    context 'with type=all (in-memory pagination)' do
      before do
        Prosopite.pause do
          6.times { |i| create_note(title: "Note #{i}") }
          6.times { |i| create_document_with_version(title: "Doc #{i}") }
        end
      end

      it 'paginates merged results' do
        Prosopite.pause do
          turbo_get knowledge_path, params: { type: 'all', items: 10 }
        end
        item_count = rendered_row_count
        expect(item_count).to eq(10)
      end

      it 'returns remaining items on second page' do
        Prosopite.pause do
          turbo_get knowledge_path, params: { type: 'all', items: 10, page: 2 }
        end
        item_count = rendered_row_count
        expect(item_count).to eq(2)
      end

      it 'clamps page to last page when exceeding total' do
        Prosopite.pause do
          turbo_get knowledge_path, params: { type: 'all', items: 10, page: 999 }
        end
        expect(response).to have_http_status(:ok)
        item_count = rendered_row_count
        expect(item_count).to eq(2)
      end
    end

    context 'with page=0 or negative' do
      before { create_note(title: 'Note') }

      it 'treats page 0 as page 1' do
        turbo_get knowledge_path, params: { type: 'all', page: 0 }
        expect(response).to have_http_status(:ok)
        item_count = rendered_row_count
        expect(item_count).to eq(1)
      end

      it 'treats negative page as page 1' do
        turbo_get knowledge_path, params: { type: 'all', page: -5 }
        expect(response).to have_http_status(:ok)
        item_count = rendered_row_count
        expect(item_count).to eq(1)
      end
    end
  end

  # ══════════════════════════════════════════════
  # The ruled short page (D8 of doc/wissen_als_bahn_plan.md)
  # ══════════════════════════════════════════════

  # The rows the page has room for but the list did not fill are ruled across
  # the whole head, from the partial the ticket table shares. A ruled row
  # carries no identity attribute, so rendered_row_count never counts it.
  describe 'the ruled short page' do
    before { sign_in_with_role(admin_role) }

    it 'pads a short page to its size with rows that span the whole head' do
      create_note(title: 'Only one')
      turbo_get knowledge_path

      table = Nokogiri::HTML(response.body).css('#knowledge_results table')
      ruled = table.css('tbody tr').select { |row| row.key?('data-ruled-line') }
      head_cells = table.css('thead th').size

      expect(rendered_row_count).to eq(1)
      # The page size the controller really reads: Pageable#items_per_page asks
      # the reader's preference BEFORE the controller default, and the
      # preference has a default of its own (User::PreferenceStore, 20), so
      # the controller's `setup_pagination 10` never gets a turn for a signed-in
      # reader. Pinning that value here would pin a number the page never shows.
      expect(ruled.size).to eq(user.items_per_page_preference - 1)
      expect(ruled.map { |row| row.at_css('td')['colspan'].to_i }.uniq).to eq([head_cells])
      expect(ruled.map { |row| row['aria-hidden'] }).to all(eq('true'))
    end
  end

  # ══════════════════════════════════════════════
  # Selected item
  # ══════════════════════════════════════════════

  describe 'selected item' do
    before { sign_in_with_role(admin_role) }

    context 'with note_id param' do
      let!(:note) { create_note(title: 'Selectable Note') }

      it 'highlights the selected note row' do
        turbo_get knowledge_path, params: { note_id: note.id }
        # Selected items carry the selected-row class
        expect(highlighted_row_count).to eq(1)
      end
    end

    context 'with document_id param' do
      let!(:document) { create_document_with_version(title: 'Selectable Doc') }

      it 'highlights the selected document row' do
        turbo_get knowledge_path, params: { document_id: document.id }
        expect(highlighted_row_count).to eq(1)
      end
    end

    context 'with non-existent note_id' do
      it 'does not highlight any row' do
        create_note(title: 'Unselected')
        turbo_get knowledge_path, params: { note_id: SecureRandom.uuid }
        expect(highlighted_row_count).to eq(0)
      end
    end

    context 'with non-existent document_id' do
      it 'does not highlight any row' do
        create_document_with_version(title: 'Unselected')
        turbo_get knowledge_path, params: { document_id: SecureRandom.uuid }
        expect(highlighted_row_count).to eq(0)
      end
    end

    context 'when user lacks notes access' do
      before do
        user.memberships.destroy_all
        sign_in_with_role(documents_reader_role)
      end

      let!(:note) { create_note(title: 'Forbidden Note') }

      it 'does not select note even with note_id param' do
        turbo_get knowledge_path, params: { note_id: note.id }
        expect(highlighted_row_count).to eq(0)
      end
    end

    context 'when user lacks documents access' do
      before do
        user.memberships.destroy_all
        sign_in_with_role(notes_reader_role)
      end

      let!(:document) { create_document_with_version(title: 'Forbidden Doc') }

      it 'does not select document even with document_id param' do
        turbo_get knowledge_path, params: { document_id: document.id }
        expect(highlighted_row_count).to eq(0)
      end
    end

    context 'with note from another project' do
      it 'does not select notes from other projects' do
        other_project = create(:project, organisation: organisation)
        other_note = create(:note, project: other_project, organisation: organisation, creator: user, title: 'Other')

        turbo_get knowledge_path, params: { note_id: other_note.id }
        expect(highlighted_row_count).to eq(0)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Smart Folders
  # ══════════════════════════════════════════════

  describe 'smart folders' do
    before { sign_in_with_role(admin_role) }

    context 'with non-existent smart_folder_id' do
      it 'does not raise and renders successfully' do
        turbo_get knowledge_path, params: { smart_folder_id: SecureRandom.uuid }
        expect(response).to have_http_status(:ok)
      end
    end

    context 'with project-scoped smart folders' do
      let(:other_project) { create(:project, organisation: organisation) }

      let!(:project_folder) do
        create(:smart_folder,
               user: user, organisation: organisation, project: project,
               target_object_type: 'Note', name: 'Project Folder', is_public: true)
      end

      let!(:global_folder) do
        create(:smart_folder,
               user: user, organisation: organisation, project: nil,
               target_object_type: 'Note', name: 'Global Folder', is_public: true)
      end

      let!(:other_project_folder) do
        create(:smart_folder,
               user: user, organisation: organisation, project: other_project,
               target_object_type: 'Note', name: 'Other Project Folder', is_public: true)
      end

      it 'renders without error when smart folders exist' do
        turbo_get knowledge_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # ══════════════════════════════════════════════
  # Multi-tenancy
  # ══════════════════════════════════════════════

  describe 'multi-tenancy' do
    before { sign_in_with_role(admin_role) }

    it 'does not show notes from other organisations' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:note, project: other_project, organisation: other_org, creator: user, title: 'Foreign Note')
      end

      ActsAsTenant.current_tenant = organisation
      turbo_get knowledge_path
      expect(response.body).not_to include('Foreign Note')
      expect(rendered_row_count).to eq(0)
    end
  end

  # ══════════════════════════════════════════════
  # Turbo Stream response
  # ══════════════════════════════════════════════

  describe 'turbo stream request' do
    before { sign_in_with_role(admin_role) }

    let!(:note) { create_note(title: 'Turbo Note') }

    # No app code asks this action for a stream; a stream branch hijacked the redirect
    # chain after notes#create / documents#create (Turbo's submit Accept header is carried
    # through the 302). Details + full chain: knowledge_create_via_turbo_submit_spec.rb
    it 'still answers the page as HTML' do
      turbo_get knowledge_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include('id="knowledge_results"')
      expect_item_in_response(note)
    end
  end

  # ══════════════════════════════════════════════
  # HTML response
  # ══════════════════════════════════════════════

  describe 'HTML response' do
    before { sign_in_with_role(admin_role) }

    it 'renders index template' do
      get knowledge_path
      expect(response).to have_http_status(:ok)
    end
  end

  # ══════════════════════════════════════════════
  # Empty state
  # ══════════════════════════════════════════════

  describe 'empty state' do
    # The first-use empty card offers two create CTAs that mirror the "+" header
    # dropdown. They are gated by write permission exactly like the dropdown, so an
    # explicit positive (writer) + negative (read-only) pair guards the rights check.
    context 'as a user who can write notes and documents (admin)' do
      before { sign_in_with_role(admin_role) }

      it 'renders the first-use empty state when no content exists' do
        turbo_get knowledge_path
        expect(response).to have_http_status(:ok)
        expect(rendered_row_count).to eq(0)
      end

      it 'offers both create CTAs (note + document) in the empty card' do
        turbo_get knowledge_path
        expect(response.body).to include(new_organisation_project_note_path(organisation, project))
        expect(response.body).to include(new_organisation_project_document_path(organisation, project))
      end
    end

    context 'as a read-only user (notes reader without write rights)' do
      before { sign_in_with_role(notes_reader_role) }

      it 'omits the create CTAs when the user cannot write' do
        turbo_get knowledge_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(new_organisation_project_note_path(organisation, project))
        expect(response.body).not_to include(new_organisation_project_document_path(organisation, project))
      end
    end
  end

  describe 'meetings belong to their own area' do
    let(:meetings_reader_role) do
      role = create(:role, organisation: organisation, title: 'meetings_reader')
      create(:project_read_permission, role: role, area: 'meetings')
      role
    end

    let!(:meeting) do
      create(:meeting, project: project, organisation: organisation, creator: user,
                       title: 'Kickoff-Gespräch', create_embeddings: true, notes: 'Inhalt')
    end

    it 'lists notes and files without meeting rows, tabs or type options' do
      note = create_note
      document = create_document_with_version
      sign_in_with_role(admin_role)
      get knowledge_path

      expect(response).to have_http_status(:ok)
      expect_item_in_response(note)
      expect_item_in_response(document)
      expect_item_not_in_response(meeting)
      page = Capybara.string(response.body)
      expect(page).to have_no_css('[role="tab"]', text: 'Meetings')
      bar = page.find('[data-filter-bar-categories-value]')
      categories = JSON.parse(bar['data-filter-bar-categories-value'])
      types = categories.find { |category| category['key'] == 'type' }.fetch('options')
      expect(types.map { |option| option['value'] }).to contain_exactly('note', 'document')
    end

    it 'ignores an old meeting filter and lists the remaining knowledge' do
      note = create_note
      sign_in_with_role(admin_role)
      turbo_get knowledge_path, params: { type: 'meeting' }

      expect(response).to have_http_status(:ok)
      expect_item_in_response(note)
      expect_item_not_in_response(meeting)
    end

    it 'requires notes or documents access even when meetings are readable' do
      sign_in_with_role(meetings_reader_role)
      get knowledge_path

      expect(response).to redirect_to(organisation_project_path(organisation, project))
    end
  end
end
