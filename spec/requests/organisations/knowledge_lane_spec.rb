# frozen_string_literal: true

require 'rails_helper'

# The knowledge detail as a lane (S1 of doc/wissen_als_bahn_plan.md): the page
# head lives inside the list column, the detail is a lane on the grid the
# ticket page uses, and every partial that fills the lane's frame lies flat on
# it. A request spec because this is a markup contract: the one thing the
# slice could break silently is a page in the old shape (a head above the
# grid, a card inside the lane) with no error anywhere.
RSpec.describe 'Knowledge lane (S1)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:title) { I18n.t('views.organisations.knowledge.index.title') }
  let(:frame) { 'knowledge_display_frame' }
  # What a shell looks like in a class list: a surface, a radius, the card's
  # edge, or padding that pushes sideways. Vertical padding is the block's own.
  let(:shell) { /(^|\s)(bg-cream-50|bg-amber-50|rounded-lg|border-cream-300|border-stroke|px-\d+|p-\d+)(\s|$)/ }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def page = Capybara.string(response.body)
  def knowledge_path(**params) = organisation_project_knowledge_index_path(organisation, project, **params)

  def create_note(title: 'Eine Notiz')
    create(:note, project: project, organisation: organisation, creator: user, title: title)
  end

  def create_document
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      version = create(:document_version, document: doc, organisation: organisation, title: 'Eine Datei')
      doc.update!(current_version: version)
      doc
    end
  end

  # The class list of the root that `selector` names, from the raw body: the
  # edit and new responses are turbo streams, whose <template> Capybara does
  # not walk, and one reading serves every road.
  def root_classes(selector_regex)
    match = response.body.match(selector_regex)
    expect(match).not_to be_nil, "root not found: #{selector_regex.inspect}"
    match[1]
  end

  describe 'the grid' do
    it 'puts the head inside the list column and the lane beside it, with the split' do
      create_note
      get knowledge_path

      expect(response).to have_http_status(:ok)
      grid = 'div.layout.two-column.layout--lane[data-controller="lane-split"]'
      expect(page).to have_css(grid)
      expect(page).to have_css("#{grid} aside.column.list", text: title)
      # The bar once on the page, and inside the list column: outside it the
      # head would span the lane again.
      expect(page).to have_css('[data-controller="filter-bar"]', count: 1)
      expect(page).to have_css("#{grid} aside.column.list [data-controller=\"filter-bar\"]")
      expect(page).to have_css("#{grid} .lane-split[role=\"separator\"]")
      expect(page).to have_css("#{grid} main.column.content > turbo-frame##{frame} #knowledge-display-placeholder", visible: :all)
      expect(page).to have_no_css('aside.column.panel', visible: :all)
    end

    # The "+" menu hangs off the button, and the button stands near the end
    # of a column that clips at its edge. Off the start edge the menu ran
    # under the lane and lost its words; against the end it stays inside.
    it 'opens the "+" menu against the end of the list column' do
      get knowledge_path

      # The menu that holds the "new note" link; the bar's view chooser in the
      # same column is a dropdown too.
      menu = page.find(:xpath,
                       '//aside[contains(@class, "list")]//ul[@data-dropdown-target="menu"][.//a[contains(@href, "/notes/new")]]',
                       visible: :all)
      expect(menu[:class].split).to include('end-0')
      expect(menu[:class].split).not_to include('start-0')
    end

    it 'shows the placeholder once, with the wording index-page writes on a clean-up' do
      get knowledge_path

      expect(page).to have_css('#knowledge-display-placeholder', count: 1, visible: :all)
      expect(page).to have_css('#knowledge-display-placeholder h1', text: I18n.t('views.organisations.knowledge.index.placeholder_title'), visible: :all)
      expect(page).to have_css('[data-index-page-placeholder-title-value]', visible: :all)
      expect(I18n.exists?('views.organisations.knowledge.index.select_item_hint')).to be(false)
    end

    # The chosen row's background and its bottom line stopped at 80% of the
    # list beside an open lane (user, 10.09.2026): the narrow rule removed the
    # date cells with display: none, the ruled rows still spanned four columns,
    # and a fourth column slot appeared that only the filler rows filled. So:
    # a set table width (fixed layout needs one), the title cells under the
    # compact width: auto rule, and a narrow rule that folds the column to
    # zero width instead of taking its cells away.
    it 'keeps every column slot on every row when the date column folds' do
      create_note
      get knowledge_path

      expect(page).to have_css('#knowledge_results table.w-full')
      expect(page).to have_no_css('#knowledge_results table.min-w-full')
      expect(page).to have_css('#knowledge_results thead th.title-header')
      expect(page).to have_css('#knowledge_results tbody td.title-column')
      expect(page).to have_css('#knowledge_results thead th[data-fb-col-date] > span')
      # The type column is named, so the compact table can give it the icon's width.
      expect(page).to have_css('#knowledge_results thead th[data-column="type"]')
      expect(page).to have_css('#knowledge_results tbody td[data-column="type"]')

      narrow_block = File.read(Rails.root.join('app/assets/stylesheets/views.css'))[/@container knowledge-results[^{]*\{(.*?)\n\}/m, 1]
      expect(narrow_block).not_to be_nil
      expect(narrow_block).to match(/\[data-fb-col-date\]\s*\{[^}]*width:\s*0/m)
      expect(narrow_block).not_to match(/\[data-fb-col-date\]\s*\{[^}]*display:\s*none/m)
    end

    it 'carries the same head above the mobile list' do
      create_note
      get knowledge_path(viewport: 'mobile')

      expect(response).to have_http_status(:ok)
      expect(page).to have_css('.mobile-list-view', text: title)
      expect(page).to have_css('.mobile-list-view [data-controller="filter-bar"]', count: 1)
      expect(page).to have_no_css('.layout--lane')
    end
  end

  describe 'the lane roots' do
    let(:note_root) { /<div id="note-header" class="([^"]*)"/ }
    let(:document_root) { /<div class="(document-content[^"]*)"/ }

    it 'renders a note with one root on the page and on the frame request, flat on the lane' do
      note = create_note
      get knowledge_path(note_id: note.id)
      on_page = root_classes(note_root)
      expect(on_page.split).to include('note-content')
      expect(page).to have_css("turbo-frame##{frame} #note-header.note-content", visible: :all)

      get organisation_project_note_path(organisation, project, note, frame: 'content', frame_id: frame)
      expect(response).to have_http_status(:ok)
      expect(root_classes(note_root)).to eq(on_page)
      expect(on_page).not_to match(shell)
    end

    it 'renders a document with one root on the page and on the frame request, flat on the lane' do
      document = create_document
      get knowledge_path(document_id: document.id)
      on_page = root_classes(document_root)
      expect(page).to have_css("turbo-frame##{frame} .document-content", visible: :all)

      get organisation_project_document_path(organisation, project, document, frame: 'content', frame_id: frame)
      expect(response).to have_http_status(:ok)
      expect(root_classes(document_root)).to eq(on_page)
      expect(on_page).not_to match(shell)
      # The inner card and its head lost their shells too: one edge inside the lane.
      expect(root_classes(/<div class="([^"]*)" id="document-card">/)).not_to match(shell)
    end

    it 'renders the note forms flat as well' do
      note = create_note
      get edit_organisation_project_note_path(organisation, project, note, frame_id: frame),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(root_classes(/<div id="note-card" class="([^"]*)"/)).not_to match(shell)

      get new_organisation_project_note_path(organisation, project, frame: 'content', frame_id: frame),
          headers: { 'Turbo-Frame' => frame }
      expect(response).to have_http_status(:ok)
      expect(root_classes(/<div id="note-card" class="([^"]*)"/)).not_to match(shell)
    end

    it 'renders the version history flat as well' do
      note = create_note
      get organisation_project_note_versions_path(organisation, project, note, frame_id: frame)

      expect(response).to have_http_status(:ok)
      expect(root_classes(/<div id="note-version-history" class="([^"]*)"/)).not_to match(shell)
    end

    it 'renders the document forms flat as well' do
      document = create_document
      get edit_organisation_project_document_path(organisation, project, document, frame: 'content', frame_id: frame),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(root_classes(document_root)).not_to match(shell)

      get new_organisation_project_document_path(organisation, project, frame: 'content', frame_id: frame),
          headers: { 'Turbo-Frame' => frame }
      expect(response).to have_http_status(:ok)
      expect(root_classes(/<div id="document-new" class="([^"]*)"/)).not_to match(shell)
    end
  end

  # S2 of doc/wissen_als_bahn_plan.md: one opener, one address, one mark.
  describe 'the opener (S2)' do
    let(:selection_params) { %w[note_id document_id] }

    it 'mounts list-row on every row with the detail address, the parameter set and the frame' do
      note = create_note
      document = create_document
      get knowledge_path

      note_row = page.find("tr[data-item-id='#{note.id}']")
      expect(note_row['data-controller']).to eq('list-row')
      expect(note_row['data-action']).to eq('click->list-row#click')
      expect(note_row['data-list-row-url-value']).to eq(organisation_project_note_path(organisation, project, note))
      expect(note_row['data-list-row-id-value']).to eq(note.id)
      expect(note_row['data-list-row-param-value']).to eq('note_id')
      # The parameter set lives on the page wrapper since D9 of
      # doc/dateivorschau_plan.md (one definition, three groups); no row carries it.
      expect(note_row['data-list-row-params-value']).to be_nil
      expect(JSON.parse(page.find('.labor-layout-view', visible: :all)['data-lane-params'])['selection']).to eq(selection_params)
      expect(note_row['data-list-row-frame-value']).to eq(frame)
      expect(note_row['data-list-row-navigate-value']).to be_nil
      expect(note_row['data-item-type']).to eq('note')

      document_row = page.find("tr[data-item-id='#{document.id}']")
      expect(document_row['data-list-row-url-value']).to eq(organisation_project_document_path(organisation, project, document))
      expect(document_row['data-list-row-param-value']).to eq('document_id')
      expect(document_row['data-item-type']).to eq('document')

      # Nothing of the old opener, whose values doubled as the row's identity.
      expect(response.body).not_to include('knowledge-row')
    end

    it 'names its index once for the page address, and the same parameters for the layout controllers' do
      get knowledge_path

      wrapper = page.find('[data-index-url]', visible: :all)
      expect(wrapper['data-index-url']).to eq(organisation_project_knowledge_index_path(organisation, project))
      expect(JSON.parse(wrapper['data-layout-toggle-selection-params-value'])).to eq(selection_params)
      expect(wrapper['data-index-page-param-name-value']).to eq(selection_params.join(','))
      expect(wrapper['data-layout-toggle-selected-row-selector-value']).to eq('.selected-row[data-item-id]')
    end

    it 'marks the open row by parameter AND id' do
      note = create_note
      document = create_document

      get knowledge_path(note_id: note.id)
      expect(page).to have_css("tr[data-item-id='#{note.id}'].selected-row")
      expect(page).to have_no_css("tr[data-item-id='#{document.id}'].selected-row")

      # A note's id under the document parameter selects nothing: the mark
      # follows the parameter, not the id alone.
      get knowledge_path(document_id: note.id)
      expect(page).to have_no_css('tr.selected-row')
    end

    %w[desktop mobile].each do |viewport|
      it "ignores a stale meeting selection on #{viewport}" do
        note = create_note
        meeting = create(:meeting, project: project, organisation: organisation, creator: user,
                                   title: 'Kickoff', create_embeddings: true, notes: 'Inhalt')
        get knowledge_path(meeting_id: meeting.id, viewport: viewport)

        expect(response).to have_http_status(:ok)
        expect(page).to have_css("tr[data-item-id='#{note.id}']")
        expect(page).to have_no_css("tr[data-item-id='#{meeting.id}']")
        expect(page).to have_no_css('tr.selected-row')
        expect(page).to have_no_text('Kickoff')
      end
    end

    it 'keeps the live query on the way back from the mobile detail' do
      note = create_note
      get knowledge_path(viewport: 'mobile', note_id: note.id, type: 'note', search: 'x')

      back = page.find('.mobile-detail-view a', text: I18n.t('views.organisations.knowledge.index.mobile_list_view'))
      query = Rack::Utils.parse_nested_query(URI.parse(back[:href]).query)
      expect(query).to include('type' => 'note', 'search' => 'x')
      expect(query).not_to include('note_id')
    end

    it 'lets the phone\'s "+" leave the page, and renders the form from the address' do
      get knowledge_path(viewport: 'mobile')
      expect(page).to have_css("a[href*='/notes/new'][data-turbo-frame='_top']", visible: :all)
      expect(page).to have_css("a[href*='/documents/new'][data-turbo-frame='_top']", visible: :all)

      get knowledge_path
      expect(page).to have_css("a[href*='/notes/new'][data-turbo-frame='#{frame}']", visible: :all)

      # A plain request to new (no frame to fill) comes back here with the state.
      get new_organisation_project_note_path(organisation, project, frame: 'content', frame_id: frame)
      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, new: 'note'))
      get new_organisation_project_document_path(organisation, project, frame: 'content', frame_id: frame)
      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, new: 'document'))

      get knowledge_path(new: 'note')
      expect(page).to have_css("turbo-frame##{frame} #note-card form", visible: :all)
      # The lane is OPEN for a form state, and index-page leaves the frame alone
      # (`new` among its skip parameters): a closed lane hid the form on a page load.
      expect(page).to have_css('.labor-layout-view.show-content', visible: :all)
      # The form state is in the page's parameter groups (D9 of doc/dateivorschau_plan.md).
      expect(JSON.parse(page.find('.labor-layout-view', visible: :all)['data-lane-params'])['form']).to eq(%w[new])
      get knowledge_path(new: 'document')
      expect(page).to have_css("turbo-frame##{frame} #document-new form", visible: :all)
      # With its fields: the new document needs its first version built, as
      # documents#new does; the page state built none and rendered an empty form.
      expect(page).to have_css("turbo-frame##{frame} #document-new form input[type=file]", visible: :all)
      expect(page).to have_css("turbo-frame##{frame} #document-new form input[type=text][data-upload-zone-target='title']", visible: :all)
      expect(page).to have_css('.labor-layout-view.show-content', visible: :all)
      get knowledge_path(new: 'note', viewport: 'mobile')
      expect(page).to have_css(".mobile-detail-view turbo-frame##{frame} #note-card form", visible: :all)
    end

    # The dashboard's "+" asks for notes/new without any frame parameter. Until 2026-09-30
    # that rendered a page of its own, with a Markdown editor from 2016 that fetched a
    # dictionary and an icon font from two foreign hosts. There is one note form, and it
    # lives on this page.
    it 'has no second note form: a request for notes/new without a frame lands here too' do
      get new_organisation_project_note_path(organisation, project)
      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, new: 'note'))

      # A frame that asks without frame=content has no form to fill either.
      get new_organisation_project_note_path(organisation, project), headers: { 'Turbo-Frame' => frame }
      expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation, project, new: 'note'))

      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<lexxy-editor')
      expect(response.body).not_to include('markdown-editor', 'simplemde')

      # The dashboard's "+" names that address outright, without the hop over notes/new.
      get organisation_project_path(organisation, project)
      expect(response.body).to include(CGI.escapeHTML(organisation_project_knowledge_index_path(organisation, project, new: 'note')))
      expect(response.body).not_to match(%r{/notes/new["'?]})
    end

    it 'renders no form from the address for a reader who may not write, nor for a type that is not one' do
      reader = create(:user)
      role = create(:role, organisation: organisation, title: 'notes_reader')
      create(:project_read_permission, role: role, area: 'notes')
      create(:membership, user: reader, organisation: organisation, role: role, active: true)
      sign_in reader

      get knowledge_path(new: 'note')
      expect(response).to have_http_status(:ok)
      expect(page).to have_no_css('#note-card', visible: :all)
      expect(page).to have_css('#knowledge-display-placeholder', visible: :all)

      sign_in user
      get knowledge_path(new: 'meeting')
      expect(page).to have_no_css('form[action*="meetings"]', visible: :all)
      expect(page).to have_css('#knowledge-display-placeholder', visible: :all)
    end

    it 'addresses the row by its identity after a save and after a delete' do
      note = create_note
      patch organisation_project_note_path(organisation, project, note),
            params: { note: { title: 'Neu' }, frame_id: frame },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("tr[data-item-id=&#39;#{note.id}&#39;]")
      expect(response.body).to include("data-item-id=\"#{note.id}\"")

      delete organisation_project_note_path(organisation, project, note),
             params: { frame_id: frame },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("tr[data-item-id=&#39;#{note.id}&#39;]")
    end
  end

  # S3 of doc/wissen_als_bahn_plan.md (D4): the lane's head, after the
  # ticket's. Type word where the ticket has its number, pencil for writers,
  # divider, ✕; the title one step under the page title; below lg the ✕
  # steps aside and the way back is a word, a link to the page address
  # without the selection and with the live query.
  describe 'the lane head (S3)' do
    let(:note_word) { I18n.t('views.organisations.knowledge.knowledge_row.note_type') }
    let(:document_word) { I18n.t('views.organisations.knowledge.knowledge_row.document_type') }

    def head_within(scope)
      page.find("#{scope} [data-lane-head]", visible: :all)
    end

    it 'crowns the note on the page and on the frame request: word, pencil, ✕, title' do
      note = create_note(title: 'Kopfzeile')
      get knowledge_path(note_id: note.id, search: 'x', type: 'note')

      head = head_within("turbo-frame##{frame} #note-header")
      expect(head).to have_text(note_word)
      expect(head).to have_css('a.note-edit-button[href*="/edit"]', visible: :all)
      expect(head).to have_css('button[data-lane-close][data-action="click->layout-toggle#closeContent"]', visible: :all)
      # No "···" on the note yet (S3 of doc/dokumentansicht_plan.md gives it to the document).
      expect(head).to have_no_css('[data-dropdown-target="menu"]', visible: :all)
      back = head.find('a[data-lane-back]', visible: :all)
      query = Rack::Utils.parse_nested_query(URI.parse(back[:href]).query)
      expect(query).to include('search' => 'x', 'type' => 'note')
      expect(query).not_to include('note_id')
      expect(page).to have_css("turbo-frame##{frame} #note-header h2[data-lane-title]", text: 'Kopfzeile', visible: :all)

      get organisation_project_note_path(organisation, project, note, frame: 'content', frame_id: frame, search: 'x', type: 'note')
      head = head_within("turbo-frame##{frame} #note-header")
      expect(head).to have_text(note_word)
      expect(head).to have_css('a.note-edit-button', visible: :all)
      back = head.find('a[data-lane-back]', visible: :all)
      expect(Rack::Utils.parse_nested_query(URI.parse(back[:href]).query)).to include('search' => 'x')
    end

    it 'crowns the document the same way' do
      document = create_document
      get knowledge_path(document_id: document.id)

      head = head_within("turbo-frame##{frame} .document-content")
      expect(head).to have_text(document_word)
      expect(head).to have_css('a.document-edit-button[href*="/edit"]', visible: :all)
      expect(head).to have_css('button[data-lane-close]', visible: :all)
      expect(page).to have_css("turbo-frame##{frame} .document-content h2[data-lane-title]", text: 'Eine Datei', visible: :all)

      # The "···" between the pencil and the divider (S3 of doc/dokumentansicht_plan.md):
      # rename opens the pencil's form, delete takes the whole document, with the confirm.
      menu = head.find('[data-dropdown-target="menu"]', visible: :all)
      dc = 'views.organisations.documents.document_content_for_frame'
      expect(menu).to have_css('a[href*="/edit"]', text: I18n.t("#{dc}.rename"), visible: :all)
      expect(menu).to have_css('a[data-turbo-method="delete"][data-turbo-confirm]', text: I18n.t("#{dc}.delete_document"), visible: :all)
    end

    it 'gives a reader the head without the pencil' do
      reader = create(:user)
      role = create(:role, organisation: organisation, title: 'notes_reader')
      create(:project_read_permission, role: role, area: 'notes')
      create(:membership, user: reader, organisation: organisation, role: role, active: true)
      note = create_note
      sign_in reader

      get knowledge_path(note_id: note.id)
      head = head_within("turbo-frame##{frame} #note-header")
      expect(head).to have_text(note_word)
      expect(head).to have_no_css('a.note-edit-button', visible: :all)
      expect(head).to have_css('button[data-lane-close]', visible: :all)
    end

    it 'puts the head over the forms too, with the word and the ✕' do
      # Both records before the first request: a request resets the tenant
      # the factories need.
      note = create_note
      document = create_document
      get edit_organisation_project_note_path(organisation, project, note, frame_id: frame),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response.body).to include('data-lane-head').and include(note_word)
      get knowledge_path(new: 'note')
      expect(page).to have_css("turbo-frame##{frame} #note-card [data-lane-head]", text: note_word, visible: :all)

      get edit_organisation_project_document_path(organisation, project, document, frame: 'content', frame_id: frame),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response.body).to include('data-lane-head').and include(document_word)
      get knowledge_path(new: 'document')
      expect(page).to have_css("turbo-frame##{frame} #document-new [data-lane-head]", text: document_word, visible: :all)
    end

    it 'shows no word back on the mobile page, which has its own way back above the detail' do
      note = create_note
      get knowledge_path(viewport: 'mobile', note_id: note.id)

      head = head_within('.mobile-detail-view #note-header')
      expect(head).to have_text(note_word)
      expect(head).to have_no_css('a[data-lane-back]', visible: :all)
      expect(page).to have_css('.mobile-detail-view a', text: I18n.t('views.organisations.knowledge.index.mobile_list_view'))
    end
  end
end
