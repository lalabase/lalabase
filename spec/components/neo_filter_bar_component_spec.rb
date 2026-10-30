# frozen_string_literal: true

require 'rails_helper'

# The filter bar rebuilt along the Belegungstabelle (doc/filterleiste_s1_s4_plan.md).
# Row 1 shows the saved views as tabs (F10): the base view first, the active one
# marked by an ink underline and weight, nothing else. The old pill assertions
RSpec.describe NeoFilterBarComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:viewer) { create(:user, first_name: 'View', last_name: 'Er') }
  # User who is referenced by a filter but is NOT in the project's assignee
  # options pool (the situation that produced the raw-UUID chip bug).
  let(:referenced_user) { create(:user, first_name: 'Test', last_name: 'Existing') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: viewer, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: referenced_user, organisation: organisation, role: admin_role, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def build(smart_folders: [], active_smart_folder: nil, ad_hoc_filters: {}, dissolver_result: nil, **overrides)
    described_class.new(
      **{
        smart_folders: smart_folders,
        url: '/test/list',
        frame_id: 'test_list_frame',
        i18n_scope: 'views.organisations.tickets.index',
        all_items_label: 'Alle Tickets',
        smart_folder_context_type: 'Ticket',
        smart_folder_return_to: 'tickets',
        active_smart_folder: active_smart_folder,
        dissolver_result: dissolver_result,
        ad_hoc_filters: ad_hoc_filters,
        ad_hoc_operators: {},
        filter_categories_json: '[]',
        search_value: nil,
        search_mode: 'content',
        project: project,
        organisation: organisation
      }.merge(overrides)
    )
  end

  def folder(name, **attrs)
    create(:smart_folder, { name: name, organisation: organisation, project: project,
                            user: viewer, target_object_type: 'Ticket' }.merge(attrs))
  end

  describe 'view tabs (F10)' do
    let(:folders) { [folder('Eilig'), folder('Meine offenen')] }

    it 'renders the base view first, then the folders in the order given' do
      render_inline(build(smart_folders: folders))

      names = page.all('a[role="tab"]').map { |tab| tab.text.strip }
      expect(names).to eq(['Alle Tickets', 'Eilig', 'Meine offenen'])
    end

    it 'links every tab to the address of its view' do
      render_inline(build(smart_folders: folders))

      hrefs = page.all('a[role="tab"]').map { |tab| tab[:href] }
      expect(hrefs.first).to eq('/test/list')
      expect(hrefs[1]).to eq("/test/list?smart_folder_id=#{folders.first.id}")
    end

    it 'keeps the query the bar was given when it adds the folder id, except a view of its own (?type=, S7)' do
      render_inline(build(smart_folders: folders, url: '/k?type=note&items=25'))

      href = page.find(%(a[role="tab"][href*="#{folders.first.id}"]))[:href]
      expect(href).to include('items=25')
      expect(href).not_to include('type=note')
      expect(href).to include("smart_folder_id=#{folders.first.id}")
    end

    it 'marks the active folder by underline and weight, not by colour or icon' do
      render_inline(build(smart_folders: folders, active_smart_folder: folders.first))

      active = page.find('a[role="tab"][aria-selected="true"]')
      expect(active.text).to include('Eilig')
      expect(active[:class]).to include('border-ink', 'font-semibold')
      expect(active[:class]).not_to include('lime')
      expect(active).not_to have_css('i.bi-check2')
    end

    it 'gives inactive tabs the same underline in transparent so nothing jumps' do
      render_inline(build(smart_folders: folders, active_smart_folder: folders.first))

      inactive = page.all('a[role="tab"][aria-selected="false"]')
      expect(inactive.size).to eq(2)
      expect(inactive.map { |tab| tab[:class] }).to all(include('border-b-2', 'border-transparent'))
    end

    it 'treats the base view as active while no folder is active' do
      render_inline(build(smart_folders: folders))

      expect(page.find('a[role="tab"][aria-selected="true"]').text).to include('Alle Tickets')
    end

    # Was "every folder is a tab, no cutoff" until 20a (D1): a tab that has to
    # be wiped sideways is worse to reach than a list with a count. Every view
    # is still reachable, five in the row and the rest one click away.
    it 'keeps every folder reachable, in the row or in the menu beside it' do
      many = Array.new(8) { |i| folder("Folder #{i}", position: i) }
      render_inline(build(smart_folders: many))

      in_row = page.all('a[role="tab"]').map { |tab| tab.text.strip }
      in_menu = page.all('[data-filter-bar-target="overflowMenu"] a[role="menuitem"]', visible: :all).map(&:text)

      expect(in_row.size).to eq(described_class::VISIBLE_TABS)
      expect(in_row + in_menu).to match_array(['Alle Tickets'] + many.map(&:name))
    end

    it 'carries the (hidden) unsaved dot only in the active saved view, never in the base view' do
      render_inline(build(smart_folders: folders, active_smart_folder: folders.first))
      expect(page).to have_css('a[role="tab"][aria-selected="true"] [data-filter-bar-target="unsavedDot"].hidden', count: 1)

      render_inline(build(smart_folders: folders))
      expect(page).not_to have_css('[data-filter-bar-target="unsavedDot"]')
    end

    it 'leaves no lime and no pill markup in the whole bar' do
      render_inline(build(smart_folders: folders, active_smart_folder: folders.first))

      expect(page.native.to_html).not_to include('lime')
      expect(page).not_to have_css('button[data-smart-folder-id]')
    end
  end

  describe 'the menu at the active tab (S5)' do
    let(:eilig) { folder('Eilig') }
    let(:all_allowed) { { rename: true, share: true, delete: true } }
    let(:menu) { page.find('[data-filter-bar-target="viewMenu"]', visible: :all) }

    it 'puts the chevron at the active tab only, base view included' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed))
      expect(page).to have_css('button[data-filter-bar-target="viewMenuButton"]', count: 1)
      expect(page).to have_css('a[role="tab"][aria-selected="true"] + button[data-filter-bar-target="viewMenuButton"]')

      render_inline(build(smart_folders: [eilig]))
      expect(page).to have_css('a[role="tab"][aria-selected="true"] + button[data-filter-bar-target="viewMenuButton"]', count: 1)
    end

    # The chevron is a control of its own beside the word (designer, 09.09.2026):
    # a 28 x 28 tile with the glyph centred by grid, titled, without the word's
    # underline; the ONE chevron of the row, drawn as SVG, no icon font.
    it 'gives the chevron its own titled tile beside the word, without the underline' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed))

      tile = page.find('button[data-filter-bar-target="viewMenuButton"]')
      expect(tile[:class]).to include('grid', 'place-items-center', 'h-7', 'w-7', 'rounded-md', 'hover:bg-cream-100', 'focus-visible:bg-cream-100')
      expect(tile[:class]).not_to include('border-ink', 'border-b-2')
      expect(tile[:title]).to eq(I18n.t('components.filter_bar.view_menu'))
      expect(tile).to have_css('svg[stroke="currentColor"][data-filter-bar-target="viewMenuChevron"]')
      expect(page.find('a[role="tab"][aria-selected="true"]')[:class]).to include('border-b-2', 'border-ink')
      expect(page).not_to have_css('.bi-chevron-down')
      expect(page.find('span:has(> a[role="tab"][aria-selected="true"])')[:class]).to include('items-center')
    end

    it 'offers rename, share, the expert filter and delete when the call site allows all three' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed))

      expect(menu).to have_button(I18n.t('components.filter_bar.rename'), visible: :all)
      expect(menu).to have_link(I18n.t('components.filter_bar.share'), visible: :all)
      expect(menu).to have_link(I18n.t('components.filter_bar.open_expert_filter'), visible: :all)
      expect(menu).to have_button(I18n.t('components.filter_bar.delete_view'), visible: :all)
      expect(menu['data-rename-url']).to end_with("/smart_folders/#{eilig.id}/rename")
      expect(menu['data-delete-url']).to end_with("/smart_folders/#{eilig.id}")
      expect(menu['data-view-name']).to eq('Eilig')
    end

    it 'opens the existing edit modal from the menu, unchanged door semantics' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed, smart_folder_return_to: 'knowledge'))

      link = menu.find_link(I18n.t('components.filter_bar.open_expert_filter'), visible: :all)
      expect(link[:href]).to include("/smart_folders/#{eilig.id}/edit")
      expect(link[:href]).to include('modal=true')
      expect(link[:href]).to include('return_to=knowledge')
      expect(link['data-turbo-frame']).to eq('modal')
    end

    it 'renders the rename form in the layer, prefilled and hidden until asked' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed))

      form = menu.find('form[data-filter-bar-target="renameForm"]', visible: :all)
      expect(form[:class]).to include('hidden')
      expect(form.find('input[name="name"]', visible: :all)[:value]).to eq('Eilig')
      expect(form).to have_button(I18n.t('components.filter_bar.rename_save'), visible: :all)
      # Both words are F4 (underlined, in ink); the server's reason for a
      # refused name has a slot the input points at.
      expect(form.all('button', visible: :all).map { |word| word[:class] }).to all(include('underline'))
      expect(form).to have_css('p[data-filter-bar-target="renameError"].hidden', visible: :all)
      expect(form.find('input[name="name"]', visible: :all)['aria-describedby']).to eq('filter-bar-rename-error')
    end

    it 'is a dialog, not a menu: it holds the rename form, and the destructive entry sits under a separator' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed))

      expect(menu['role']).to eq('dialog')
      expect(menu['aria-modal']).to eq('false')
      expect(menu).not_to have_css('[role="menuitem"]', visible: :all)
      expect(menu).to have_css('[role="separator"] + button', text: I18n.t('components.filter_bar.delete_view'), visible: :all)
      expect(page.find('button[data-filter-bar-target="viewMenuButton"]')['aria-haspopup']).to eq('dialog')
    end

    it 'shows only the expert filter to a reader who may neither edit, share nor delete' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: {}))

      expect(menu).not_to have_button(I18n.t('components.filter_bar.rename'), visible: :all)
      expect(menu).not_to have_link(I18n.t('components.filter_bar.share'), visible: :all)
      expect(menu).not_to have_button(I18n.t('components.filter_bar.delete_view'), visible: :all)
      expect(menu).to have_link(I18n.t('components.filter_bar.open_expert_filter'), visible: :all)
      expect(menu).not_to have_css('form', visible: :all)
      expect(menu['data-rename-url']).to be_blank
      expect(menu['data-delete-url']).to be_blank
    end

    it 'keeps delete for an owner who may not share (each entry follows its own answer)' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: { rename: true, share: false, delete: true }))

      expect(menu).to have_button(I18n.t('components.filter_bar.rename'), visible: :all)
      expect(menu).not_to have_link(I18n.t('components.filter_bar.share'), visible: :all)
      expect(menu).to have_button(I18n.t('components.filter_bar.delete_view'), visible: :all)
    end

    it 'holds only the expert filter on the base view, starting a new folder with the context type' do
      render_inline(build(smart_folders: [eilig], smart_folder_context_type: 'Note', smart_folder_return_to: 'knowledge'))

      expect(menu).to have_css('[data-filter-bar-target="viewMenuList"] a, [data-filter-bar-target="viewMenuList"] button', count: 1, visible: :all)
      link = menu.find_link(I18n.t('components.filter_bar.open_expert_filter'), visible: :all)
      expect(link[:href]).to include('/smart_folders/new')
      expect(link[:href]).to include('context_type=Note')
      expect(link[:href]).to include('return_to=knowledge')
    end

    it 'has neither pencil nor sliders symbol anywhere in the bar (B23, B24, B31)' do
      render_inline(build(smart_folders: [eilig], active_smart_folder: eilig, active_view_permissions: all_allowed))

      expect(rendered_content).not_to include('bi-pencil')
      expect(rendered_content).not_to include('bi-sliders')
      labels = JSON.parse(page.find('[data-filter-bar-labels-value]')['data-filter-bar-labels-value'])
      expect(labels).not_to have_key('edit_smart_folder')
      expect(labels).to include('renamed', 'delete_confirm', 'view_deleted')
      expect(page).not_to have_css('[data-filter-bar-new-smart-folder-url-value]')
    end

    # The pencil and the sliders entry were built by JavaScript, not by the
    # server; rendered_content above would not notice their return.
    it 'keeps pencil and sliders out of the JavaScript the bar builds from' do
      %w[app/javascript/lib/filter_bar/chip_renderer.js app/javascript/lib/filter_bar/menu_renderer.js
         app/javascript/controllers/filter_bar_controller.js].each do |file|
        source = Rails.root.join(file).read
        expect(source).not_to include('bi-pencil'), file
        expect(source).not_to include('bi-sliders'), file
      end
    end
  end

  describe 'the proposal row (F31, S6)' do
    let(:categories_json) { [{ key: 'due_date', label: 'Fällig', options: [{ value: 'this_week', label: 'diese Woche' }] }].to_json }
    let(:proposal) { { source: 'Assistent', category: 'due_date', value: 'this_week', label: 'bis Freitag' } }

    it 'renders a proposal as its own row with the source, the sentence and two words, never as a pill' do
      render_inline(build(filter_categories_json: categories_json, proposals: [proposal]))

      row = page.find('[data-filter-bar-target="proposalRow"] [data-proposal]')
      expect(row[:class]).not_to include('rounded-full')
      expect(row).to have_css('span.uppercase', text: 'Assistent')
      expect(row).to have_css('strong', text: 'Fällig: bis Freitag')
      expect(row.text).to include('Auch nach')
      expect(row).to have_button(I18n.t('components.filter_bar.accept'))
      expect(row).to have_button(I18n.t('components.filter_bar.decline'))
      # Both words are F4 (underlined, in ink): a quiet word that acts is no form of the table
      expect(row.all('button').map { |word| word[:class] }).to all(include('underline', 'text-body'))
      expect(row['data-category']).to eq('due_date')
      expect(row['data-value']).to eq('this_week')
      expect(page).not_to have_css('#filter-bar-chips [data-condition]')
    end

    it 'hides the row container while nothing is proposed, and skips a proposal without a value' do
      render_inline(build)
      expect(page.find('[data-filter-bar-target="proposalRow"]', visible: :all)[:class]).to include('hidden')

      render_inline(build(proposals: [{ source: 'x', category: 'due_date', value: '' }]))
      expect(page).not_to have_css('[data-proposal]', visible: :all)
    end

    it 'escapes what the producer sends' do
      render_inline(build(proposals: [{ source: '<b>x</b>', category: 'tag', value: '<i>y</i>', label: '<i>y</i>' }]))

      expect(rendered_content).to include('&lt;b&gt;x&lt;/b&gt;')
      expect(rendered_content).to include('&lt;i&gt;y&lt;/i&gt;')
      expect(rendered_content).not_to include('<i>y</i>')
    end
  end

  describe 'trigger and search in the tab row (F2, F35)' do
    it 'renders "+ Filter" as a secondary action, not as a pill, without a count badge' do
      render_inline(build(ad_hoc_filters: { 'status' => %w[open] }))

      trigger = page.find('button[data-filter-bar-target="filterButton"]')
      expect(trigger[:class]).to include('rounded-md')
      expect(trigger[:class]).not_to include('rounded-full', 'border-dashed')
      expect(page).not_to have_css('[data-filter-bar-target="badge"]')
    end

    # S5 of doc/kanban_ticket_als_bahn_plan.md (D2): tight, the trigger folds
    # to a sign instead of leaving the head. The word and its plus are marked
    # so the stylesheet can leave them out, the funnel is marked so it can be
    # shown. The funnel, not the sliders: those are the column tool beside it
    # (F39, one symbol, one meaning).
    it 'carries a funnel sign for the tight head, marked apart from the word' do
      render_inline(build)

      trigger = page.find('button[data-fb-add]')
      expect(trigger).to have_css('[data-fb-add-plus].bi-plus-lg', visible: :all)
      expect(trigger).to have_css('[data-fb-add-label]', visible: :all)
      expect(trigger).to have_css('[data-fb-add-sign].bi-funnel', visible: :all)
      expect(trigger).not_to have_css('.bi-sliders2', visible: :all)
    end

    # The title is the sign's word, with the count, at 0, 1 and 2 conditions;
    # the same three forms travel as labels for the controller, which
    # re-renders the title without a page load.
    it 'titles the trigger with the count of conditions, in all three forms' do
      render_inline(build)
      expect(page.find('button[data-fb-add]')[:title]).to eq('Filter')

      render_inline(build(ad_hoc_filters: { 'status' => %w[open] }))
      expect(page.find('button[data-fb-add]')[:title]).to eq('Filter · 1 Bedingung')

      render_inline(build(ad_hoc_filters: { 'status' => %w[open], 'priority' => %w[high] }))
      trigger = page.find('button[data-fb-add]')
      expect(trigger[:title]).to eq('Filter · 2 Bedingungen')
      expect(trigger['aria-label']).to eq('Filter · 2 Bedingungen')

      labels = JSON.parse(page.find('[data-filter-bar-labels-value]')['data-filter-bar-labels-value'])
      expect(labels['filter_sign_title']).to eq(
        # rubocop:disable Style/FormatStringToken -- the placeholder is filled by the controller
        'zero' => 'Filter', 'one' => 'Filter · 1 Bedingung', 'other' => 'Filter · %{count} Bedingungen'
        # rubocop:enable Style/FormatStringToken
      )
    end

    it 'renders the search as a magnifier that grows into a field naming the object' do
      render_inline(build)

      input = page.find('input[data-filter-bar-target="searchInput"]', visible: :all)
      # h-7 since 09.09.2026: the field and the tools next to it are one group
      # of 28px (F40), asserted as such below.
      expect(input[:class]).to include('h-7', 'rounded-md', 'border-cream-300')
      expect(input[:placeholder]).to eq(I18n.t('views.organisations.tickets.index.filter_bar.search_placeholder'))
      expect(input[:placeholder]).not_to match(/\.\.\./)

      # The magnifier at rest (designer, 09.09.2026): a 28 x 28 tile at every
      # width, titled with the same words the field carries; the wrapper has
      # no width of its own, the stylesheet folds and grows it.
      magnifier = page.find('button[data-fb-search-open-button]', visible: :all)
      expect(magnifier[:class]).to include('grid', 'place-items-center', 'h-7', 'w-7')
      expect(magnifier[:class]).not_to include('border-cream-300')
      expect(magnifier[:title]).to eq(I18n.t('views.organisations.tickets.index.filter_bar.search_placeholder'))
      expect(magnifier['aria-label']).to eq(magnifier[:title])
      expect(page.find('[data-filter-bar-target="search"]', visible: :all)[:class]).not_to include('w-60')
      expect(page).not_to have_css('[data-fb-depth] .bi-chevron-down', visible: :all)
    end

    # 20a, S1: the resting state of a condition is the sentence, not the pill.
    # The pills wait in their row until somebody edits, and the row that shows
    # nothing is gone rather than empty.
    it 'hides both condition rows entirely while there is no condition' do
      render_inline(build)

      expect(page.find('[data-filter-bar-target="chipRow"]', visible: :all)[:class]).to include('hidden')
      expect(page.find('[data-filter-bar-target="sentenceRow"]', visible: :all)[:class]).to include('hidden')
    end

    # Without a condition there is no sentence, and then no word stands there either:
    # a single "ändern" below the tabs says nothing and takes up a row.
    it 'leaves no lone word behind when there is nothing to say' do
      render_inline(build)

      expect(page).not_to have_css('[data-fb-prose]', visible: :all)
      expect(page).not_to have_css('[data-filter-bar-target="editWord"]', visible: :all)
    end

    it 'shows the sentence, not the pills, once there is a condition' do
      render_inline(build(ad_hoc_filters: { 'status' => %w[open] }))

      expect(page.find('[data-filter-bar-target="sentenceRow"]')[:class]).not_to include('hidden')
      expect(page.find('[data-filter-bar-target="chipRow"]', visible: :all)[:class]).to include('hidden')
    end
  end

  # F40, rewritten on 07.09.2026 (20a, D3). The first version came out of a
  # real defect (two heights, a capsule beside a box) and drew the wrong rule
  # from it: sameness in everything. What binds neighbours is height, radius
  # and font size. What must DIFFER is the fill and the edge of the one element
  # you can type into: three framed boxes of which one takes typing hide the
  # only difference that matters.
  describe 'the toolbar: one field, the rest flat (F40)' do
    it 'binds height, radius and font size across the trigger and the field' do
      render_inline(build)

      trigger = page.find('button[data-fb-add]')[:class]
      field = page.find('[data-filter-bar-target="searchInput"]', visible: :all)[:class]

      ['h-7', 'rounded-md', 'text-[13px]'].each do |shared|
        expect(trigger).to include(shared), "trigger misses #{shared}"
        expect(field).to include(shared), "search field misses #{shared}"
      end
    end

    # Three tools of equal rank in one group (designer, 09.09.2026): filter,
    # magnifier, columns, 4px apart, all 28px high, the filter word included.
    it 'stands the three tools in one group, 4px apart and all 28px high' do
      with_tool = build
      with_tool.with_view_tool { '<button id="col" class="h-7 w-7">Spalten</button>'.html_safe }
      render_inline(with_tool)

      group = page.find('[data-fb-tools]')
      expect(group[:class]).to include('gap-1')
      expect(group[:class]).not_to include('gap-1.5')
      expect(page.find('[data-fb-tools] button[data-fb-add]')[:class]).to include('h-7', 'px-2')
      expect(page.find('[data-fb-tools] button[data-fb-search-open-button]', visible: :all)[:class]).to include('h-7', 'w-7')
      expect(page.all('[data-fb-tools] > *').map { |node| node[:'data-fb-view-tool'] || node[:class] }.size).to eq(3)
    end

    it 'gives the edge and the raised surface to the field alone' do
      render_inline(build)

      trigger = page.find('button[data-fb-add]')[:class]
      field = page.find('[data-filter-bar-target="searchInput"]', visible: :all)[:class]

      expect(field).to include('border-cream-300').and include('bg-surface-raised')
      expect(trigger).not_to include('border-cream-300')
      expect(trigger).not_to include('bg-surface-raised')
    end

    it 'takes the tool of the view into the same group, and stands without one' do
      render_inline(build)
      expect(page).not_to have_css('[data-fb-view-tool]')

      with_tool = build
      with_tool.with_view_tool { '<button id="col">6 Spalten</button>'.html_safe }
      render_inline(with_tool)

      expect(page).to have_css('[data-fb-view-tool] #col')
    end
  end

  # 20a, § 4: without a copy, a reader who changes a shared view overwrites what
  # a colleague uses. With it, the copy is the easier way.
  describe 'duplicating the active view (20a, S3)' do
    let(:saved_views) { [folder('Eilig'), folder('Meine offenen')] }

    it 'offers the copy on a saved view, pointed at its clone address' do
      active = saved_views.first
      render_inline(build(smart_folders: saved_views, active_smart_folder: active))

      entry = page.find('[data-filter-bar-target="viewMenu"] button[data-action*="duplicateView"]', visible: :all)
      expect(entry.text).to eq(I18n.t('components.filter_bar.duplicate_view'))
      expect(entry[:'data-url']).to eq("/org/#{organisation.id}/smart_folders/#{active.id}/clone")
    end

    it 'offers nothing to copy on the base view' do
      render_inline(build(smart_folders: saved_views))

      expect(page).not_to have_css('[data-filter-bar-target="viewMenu"] button[data-action*="duplicateView"]', visible: :all)
    end
  end

  # 20a, D1: a tab you have to wipe sideways is worse to reach than a list with
  # a count. The number is fixed rather than measured, so the row is the same
  # before and after the JavaScript has run.
  describe 'the views that did not fit (20a, D1)' do
    let(:many) { (1..7).map { |i| folder("Ansicht #{i}") } }

    it 'keeps every view in the row while they fit' do
      render_inline(build(smart_folders: many.first(4)))

      expect(page.all('a[role="tab"]').size).to eq(5)
      expect(page).not_to have_css('[data-fb-overflow]')
    end

    it 'folds the rest into a menu that counts them' do
      render_inline(build(smart_folders: many))

      expect(page.all('a[role="tab"]').size).to eq(described_class::VISIBLE_TABS)
      expect(page).to have_css('[data-fb-overflow]', text: '3 weitere')
      expect(page.all('[data-filter-bar-target="overflowMenu"] a[role="menuitem"]', visible: :all).map(&:text))
        .to eq(['Ansicht 5', 'Ansicht 6', 'Ansicht 7'])
      # The word alone (designer, 09.09.2026): a listing, not a second opener.
      expect(page).not_to have_css('[data-fb-overflow] i, [data-fb-overflow] svg', visible: :all)
    end

    # A view you cannot see is a view you cannot tell is yours: it carries the
    # underline, the chevron and the amber dot.
    it 'never folds the active view away' do
      render_inline(build(smart_folders: many, active_smart_folder: many.last))

      expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: 'Ansicht 7')
      expect(page.all('a[role="tab"]').size).to eq(described_class::VISIBLE_TABS)
      expect(page).to have_css('[data-fb-overflow]', text: '3 weitere')
    end
  end

  # 20a, S1: a filter is read many times and changed once, so the resting state
  # is prose. The grammar itself is pinned in the service spec; here only the
  # wiring is: the right words, the right targets, and one request per editing
  # session instead of one per tick.
  describe 'the conditions as a sentence (20a, S1)' do
    it 'says the conditions as one sentence, in the words of the area' do
      render_inline(build(ad_hoc_filters: { 'status' => %w[open], 'tag' => %w[Kunde] }))

      expect(page.find('[data-fb-prose]').text.squish)
        .to start_with('Nur Aufgaben, die').and include('haben')
    end

    it 'makes every value a target of its own, and nothing else in the sentence' do
      render_inline(build(ad_hoc_filters: { 'status' => %w[open] }))

      values = page.all('[data-fb-prose] button[data-category]')
      expect(values.map { |v| v[:'data-category'] }).to eq(%w[status])
      expect(values.first[:title]).to eq(I18n.t('components.filter_bar.change_value'))
    end

    it 'carries the word that opens the pills, at the end of the sentence' do
      render_inline(build(ad_hoc_filters: { 'status' => %w[open] }))

      expect(page).to have_css('[data-filter-bar-target="editWord"]',
                               text: I18n.t('components.filter_bar.edit_conditions'))
      expect(page).to have_css('[data-filter-bar-target="chipRow"] [data-fb-word]',
                               text: I18n.t('components.filter_bar.done_editing'), visible: :all)
    end

    it 'gives the sentence its own frame, so an edit does not rebuild it' do
      render_inline(build(ad_hoc_filters: { 'status' => %w[open] }))

      expect(page).to have_css('turbo-frame#test_list_frame_sentence [data-filter-bar-target="sentenceRow"]')
    end

    it 'says the reader as "mir" where the condition names them' do
      render_inline(build(ad_hoc_filters: { 'assignee' => [referenced_user.id] }, current_user_id: referenced_user.id))

      expect(page.find('[data-fb-prose]').text.squish).to include('mir zugewiesen')
    end
  end

  describe 'narrow (rule 7, S8) and the layers' do
    it 'marks the search, the magnifier button and the trigger for the container rules' do
      render_inline(build)

      search = page.find('[data-filter-bar-target="search"]', visible: :all)
      expect(search['data-fb-search']).not_to be_nil
      expect(search['data-fb-search-open']).to be_nil
      expect(search).to have_css('button[data-fb-search-open-button][aria-label]', visible: :all)
      expect(page).to have_css('button[data-fb-add] [data-fb-add-label]')
      # The fold is no longer tight-only: the closed search is 28px at every
      # width and the field opens on click (the top of the stylesheet).
      css = Rails.root.join('app/assets/stylesheets/components/filter_bar.css').read
      general = css[/\A.*?@container filter-bar \(max-width: 760px\)/m]
      expect(general).to include('[data-fb-search]:not([data-fb-search-open]) {')
      expect(general).to include('width: 28px')
      expect(general).to include('[data-fb-search][data-fb-search-open] [data-fb-search-open-button]')
    end

    it 'keeps the search open while a term stands in it' do
      render_inline(build(search_value: 'kasse'))

      expect(page.find('[data-filter-bar-target="search"]', visible: :all)['data-fb-search-open']).not_to be_nil
    end

    it 'names the layers for assistive tech' do
      render_inline(build)

      # A dialog, not a menu: the layer opens with a head that holds a close,
      # and a menu may own nothing but its items. The list inside it, built by
      # the controller, keeps role="menu" and with it the arrow keys.
      expect(page).to have_css('[data-filter-bar-target="filterMenu"][role="dialog"][aria-label]', visible: :all)
      expect(page).to have_css('[data-filter-bar-target="categoryList"]', visible: :all)
      expect(page).to have_css('[data-filter-bar-target="valueMenu"][role="dialog"]', visible: :all)
      expect(page).to have_css('[data-filter-bar-target="viewMenu"][role="dialog"][aria-label]', visible: :all)
      expect(page).to have_css('[data-fb-tabrow]')
    end

    it 'loads the container rules from their own stylesheet' do
      css = Rails.root.join('app/assets/stylesheets/components/filter_bar.css').read
      expect(css).to include('@container filter-bar (max-width: 520px)')
      expect(css).to include('[data-fb-close]')
      expect(Rails.root.join('app/assets/stylesheets/application.css').read).to include('require components/filter_bar')
    end

    # The tight band folds the trigger instead of leaving it out (S5, D2): a
    # reading of the stylesheet, because the container query itself only a
    # browser can prove (759/760/761 by hand).
    it 'folds the trigger to its sign in the tight band instead of leaving it out' do
      css = Rails.root.join('app/assets/stylesheets/components/filter_bar.css').read
      tight = css[/@container filter-bar \(max-width: 760px\) \{.*?\n\}\n/m]
      expect(tight).to include('[data-fb-add-label]')
      expect(tight).to include('[data-fb-add-sign]')
      expect(tight).not_to match(/\[data-fb-add\]\s*\{\s*display:\s*none/)
    end
  end

  describe 'save row and flash (F23, F25)' do
    it 'renders the save row slot under the conditions, empty and hidden until the state differs' do
      render_inline(build)

      row = page.find('[data-filter-bar-target="saveRow"]', visible: :all)
      expect(row[:class]).to include('hidden')
      expect(row.text).to eq('')
      # Order in the DOM: tabs, then conditions, then the save row.
      html = page.native.to_html
      expect(html.index('data-filter-bar-target="chipRow"')).to be < html.index('data-filter-bar-target="saveRow"')
    end

    it 'renders the flash as templates from NeoFlashComponent, one green and one red' do
      render_inline(build)

      # Nokogiri parks <template> children in a fragment, so read the raw HTML.
      success = rendered_content[%r{<template data-filter-bar-target="flashTemplate">(.*?)</template>}m, 1]
      expect(success).to include('data-controller="neo-flash"')
      expect(success).to include('bg-green-100')
      expect(success).to include('data-neo-flash-hide-delay-value="2500"')
      error = rendered_content[%r{<template data-filter-bar-target="errorFlashTemplate">(.*?)</template>}m, 1]
      expect(error).to include('bg-red-100')
    end
  end

  describe 'value labels for referenced users (assignee/creator chips)' do
    it 'maps an assignee user-id to the user display name' do
      labels = JSON.parse(build(ad_hoc_filters: { 'assignee' => [referenced_user.id] }).send(:value_labels_json))
      expect(labels[referenced_user.id]).to eq(referenced_user.display_name)
    end

    # A user without a name is labelled like everywhere else, never by a hidden
    # login address (User::EmailDisplay).
    it 'never labels a nameless user by a hidden login address' do
      referenced_user.update!(first_name: nil, last_name: nil, email: 'ghost-login@example.com', email_visibility: 'none')

      labels = JSON.parse(build(ad_hoc_filters: { 'assignee' => [referenced_user.id] }).send(:value_labels_json))

      expect(labels[referenced_user.id]).to eq(I18n.t('users.unnamed'))
    end

    it 'maps a creator user-id to the user display name' do
      labels = JSON.parse(build(ad_hoc_filters: { 'creator' => [referenced_user.id] }).send(:value_labels_json))
      expect(labels[referenced_user.id]).to eq(referenced_user.display_name)
    end

    it 'maps assignee user-ids that come only from the dissolved smart folder' do
      dissolver = double('dissolver_result',
                         ad_hoc_filters: { 'assignee' => [referenced_user.id] },
                         ad_hoc_operators: { 'assignee' => 'or' },
                         complex_rules: [])
      labels = JSON.parse(build(dissolver_result: dissolver).send(:value_labels_json))
      expect(labels[referenced_user.id]).to eq(referenced_user.display_name)
    end

    it 'maps assignee user-ids referenced by a complex (non-dissolvable) rule' do
      rule = double('rule', field: 'assignee', value: referenced_user.id)
      dissolver = double('dissolver_result',
                         ad_hoc_filters: {},
                         ad_hoc_operators: {},
                         complex_rules: [rule])
      labels = JSON.parse(build(dissolver_result: dissolver).send(:value_labels_json))
      expect(labels[referenced_user.id]).to eq(referenced_user.display_name)
    end

    it 'returns an empty object when no user-typed filters are referenced' do
      labels = JSON.parse(build(ad_hoc_filters: { 'status' => ['Offen'] }).send(:value_labels_json))
      expect(labels).to eq({})
    end

    it 'does not include status/priority values (only user references)' do
      labels = JSON.parse(build(ad_hoc_filters: { 'assignee' => [referenced_user.id], 'status' => ['Offen'] }).send(:value_labels_json))
      expect(labels.keys).to contain_exactly(referenced_user.id)
    end

    # The ids come from the address. User is not tenant-scoped, so without
    # this scope any signed-in reader could turn a known id of ANY organisation
    # into a name through ?filter[assignee][]=<id>.
    it 'does not resolve a user who is not a member of the organisation' do
      stranger = create(:user, first_name: 'Some', last_name: 'Stranger')
      labels = JSON.parse(build(ad_hoc_filters: { 'assignee' => [stranger.id, referenced_user.id] }).send(:value_labels_json))
      expect(labels.keys).to contain_exactly(referenced_user.id)
    end
  end

  describe 'context parametrization' do
    it 'renders the given url and frame id as filter-bar values' do
      render_inline(build(url: '/my/custom/list', frame_id: 'custom_frame'))

      expect(page).to have_css('[data-filter-bar-url-value="/my/custom/list"]')
      expect(page).to have_css('[data-filter-bar-frame-value="custom_frame"]')
    end

    it 'renders the given all-items label on the base tab' do
      render_inline(build(smart_folders: [folder('Eilig')], all_items_label: 'Alle Wissensobjekte'))

      expect(page.first('a[role="tab"]').text).to include('Alle Wissensobjekte')
    end

    it 'builds the new-smart-folder URL of the base view menu from the given context type and return target' do
      render_inline(build(smart_folder_context_type: 'Note', smart_folder_return_to: 'knowledge'))

      new_url = page.find('[data-filter-bar-target="viewMenuList"] a', visible: :all)[:href]
      expect(new_url).to include('context_type=Note')
      expect(new_url).to include('return_to=knowledge')
      expect(new_url).to include("project_id=#{project.id}")
    end

    it 'resolves area labels from the given i18n scope and the bar words from the shared scope' do
      render_inline(build)

      expect(page).to have_text(I18n.t('views.organisations.tickets.index.filter_bar.add_filter'))
      labels = JSON.parse(page.find('[data-filter-bar-labels-value]')['data-filter-bar-labels-value'])
      expect(labels['no_filter_options']).to eq(I18n.t('views.organisations.tickets.index.no_filter_options'))
      expect(labels['save_as_view']).to eq(I18n.t('components.filter_bar.save_as_view'))
      expect(labels['condition_count']).to eq('one' => I18n.t('components.filter_bar.condition_count.one'),
                                              'other' => I18n.t('components.filter_bar.condition_count.other'))
    end

    it 'hands the dropped saved categories to the controller' do
      render_inline(build(dropped_categories: %w[status]))

      expect(page.find('[data-filter-bar-dropped-value]')['data-filter-bar-dropped-value']).to eq('["status"]')
    end

    it 'appends target_object_type and return_to to the save URL when given (PE-B)' do
      render_inline(build(save_target_object_type: 'Note', smart_folder_return_to: 'knowledge'))

      save_url = page.find('[data-filter-bar-save-url-value]')['data-filter-bar-save-url-value']
      expect(save_url).to include('target_object_type=Note')
      expect(save_url).to include('return_to=knowledge')
    end

    it 'keeps the save URL clean without a save target (Tickets-Bestandsverhalten)' do
      render_inline(build)

      save_url = page.find('[data-filter-bar-save-url-value]')['data-filter-bar-save-url-value']
      expect(save_url).not_to include('target_object_type')
      expect(save_url).not_to include('return_to')
    end
  end

  describe 'built-in type views (knowledge, S7)' do
    let(:knowledge_scope) { 'views.organisations.knowledge.index' }
    let(:builtin_views) do
      [
        { key: 'note', name: 'Notizen', url: '/k?type=note', active: false },
        { key: 'document', name: 'Dateien', url: '/k?type=document', active: true }
      ]
    end
    let(:builtin_result) do
      double('dissolver_result', dissolvable?: true, ad_hoc_filters: { 'type' => ['document'] }, ad_hoc_operators: {}, complex_rules: [])
    end

    it 'renders the built-in views as tabs between the base view and the folders, and no select' do
      render_inline(build(smart_folders: [folder('Eilig')], builtin_views: builtin_views, i18n_scope: knowledge_scope, url: '/k?type=document'))

      names = page.all('a[role="tab"]').map { |tab| tab.text.strip }
      expect(names).to eq(['Alle Tickets', 'Notizen', 'Dateien', 'Eilig'])
      expect(page).not_to have_css('select#knowledge-type-select')
      expect(page).not_to have_css('label[for="knowledge-type-select"]')
    end

    it 'strips the caller\'s ?type= from the base address and gives every view its own' do
      render_inline(build(smart_folders: [folder('Eilig')], builtin_views: builtin_views, url: '/k?type=document&sort[column]=title'))

      hrefs = page.all('a[role="tab"]').map { |tab| tab[:href] }
      expect(hrefs[0]).to eq('/k?sort%5Bcolumn%5D=title')
      expect(hrefs[1]).to eq('/k?sort%5Bcolumn%5D=title&type=note')
      expect(hrefs[3]).to include('smart_folder_id=')
      expect(hrefs[3]).not_to include('type=')
      expect(page.find('[data-filter-bar-url-value]')['data-filter-bar-url-value']).to eq('/k?sort%5Bcolumn%5D=title')
    end

    it 'marks the active built-in view, hands the controller its key, and keeps the dot slot' do
      render_inline(build(builtin_views: builtin_views, dissolver_result: builtin_result, url: '/k?type=document'))

      active = page.find('a[role="tab"][aria-selected="true"]')
      expect(active.text).to include('Dateien')
      expect(active).to have_css('[data-filter-bar-target="unsavedDot"]', visible: :all)
      expect(page).to have_css('[data-filter-bar-view-key-value="document"]')
      dissolver = JSON.parse(page.find('[data-filter-bar-dissolver-value]')['data-filter-bar-dissolver-value'])
      expect(dissolver['filters']).to eq('type' => ['document'])
      expect(page.find('[data-filter-bar-target="sentenceRow"]', visible: :all)[:class]).not_to include('hidden')
    end

    it 'gives a built-in view a menu with the expert filter only, no rename, share or delete' do
      render_inline(build(builtin_views: builtin_views, dissolver_result: builtin_result, url: '/k?type=document'))

      menu = page.find('[data-filter-bar-target="viewMenu"]', visible: :all)
      expect(menu).to have_css('[data-filter-bar-target="viewMenuList"] a, [data-filter-bar-target="viewMenuList"] button', count: 1, visible: :all)
      expect(menu['data-view-name']).to eq('Dateien')
      expect(menu['data-rename-url']).to be_blank
    end

    # The type category (S7) is the folder's target in the making. A folder
    # whose target is one type cannot take it (immutable, never a pill: D4), so
    # "+ Filter" does not offer it there; the base view, a built-in view and a
    # folder of all types do, and a save from them makes the type the target.
    it 'offers the type category everywhere but on a folder with a single-type target' do
      categories = [{ key: 'type', label: 'Typ' }, { key: 'tag', label: 'Tag' }].to_json
      keys = -> { JSON.parse(page.find('[data-filter-bar-categories-value]')['data-filter-bar-categories-value']).map { |c| c['key'] } }

      render_inline(build(filter_categories_json: categories, builtin_views: builtin_views))
      expect(keys.call).to eq(%w[type tag])

      note_folder = folder('Notizen-Ordner', target_object_type: 'Note')
      render_inline(build(smart_folders: [note_folder], active_smart_folder: note_folder, filter_categories_json: categories))
      expect(keys.call).to eq(%w[tag])

      all_folder = folder('Alles-Ordner', target_object_type: 'All')
      render_inline(build(smart_folders: [all_folder], active_smart_folder: all_folder, filter_categories_json: categories))
      expect(keys.call).to eq(%w[type tag])
    end

    it 'hands the folder targets of the types to the controller and leaves the save URL without a target' do
      render_inline(build(builtin_views: builtin_views, type_targets: { 'note' => 'Note', 'document' => 'Document', 'meeting' => nil },
                          save_target_object_type: 'Document', smart_folder_return_to: 'knowledge'))

      targets = JSON.parse(page.find('[data-filter-bar-type-targets-value]')['data-filter-bar-type-targets-value'])
      expect(targets).to eq('note' => 'Note', 'document' => 'Document', 'meeting' => nil)
      save_url = page.find('[data-filter-bar-save-url-value]')['data-filter-bar-save-url-value']
      expect(save_url).to include('return_to=knowledge')
      expect(save_url).not_to include('target_object_type')
    end

    it 'renders no built-in tabs and an empty view key without built-in views (tickets)' do
      render_inline(build(smart_folders: [folder('Eilig')]))

      expect(page.all('a[role="tab"]').size).to eq(2)
      expect(page).to have_css('[data-filter-bar-view-key-value=""]')
    end
  end

  describe 'smart folder type badges on tabs (mixed folder lists)' do
    let(:note_folder) { folder('Notiz-Folder', target_object_type: 'Note') }

    it 'shows a badge icon for the folder type when icons are configured' do
      render_inline(build(smart_folders: [note_folder], type_badge_icons: { 'Note' => 'bi-journal-text' }))

      tab = page.find(%(a[role="tab"][href*="#{note_folder.id}"]))
      expect(tab).to have_css('i.bi-journal-text')
    end

    it 'shows no badge without configured icons (tickets context)' do
      render_inline(build(smart_folders: [note_folder]))

      tab = page.find(%(a[role="tab"][href*="#{note_folder.id}"]))
      expect(tab).not_to have_css('i.bi-journal-text')
    end
  end

  describe 'search depth modes' do
    it 'limits the depth options to the given modes' do
      render_inline(build(search_modes: %w[title_only content]))

      expect(page).to have_css('button[data-mode="title_only"]')
      expect(page).to have_css('button[data-mode="content"]')
      expect(page).not_to have_css('button[data-mode="full"]')
    end

    it 'hides the depth selector entirely with a single mode' do
      render_inline(build(search_modes: %w[content]))

      expect(page).not_to have_css('[data-filter-bar-target="searchDepthButton"]')
      expect(page).to have_css('input[data-filter-bar-target="searchInput"]')
    end

    it 'makes the search field the keyboard entry into the rows only when asked' do
      render_inline(build)
      expect(page).not_to have_css('input[data-keyboard-navigation-target]')

      render_inline(build(keyboard_navigation: true))
      expect(page).to have_css('input[name="search"][data-keyboard-navigation-target="searchInput"]')
    end
  end
end
