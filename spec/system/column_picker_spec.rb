# frozen_string_literal: true

require 'rails_helper'

# What: the column picker in a browser (doc/spaltenwahl_plan.md, S2 to S5): open,
#   tick, move by keyboard, the boundary, the save at once, Escape, apply to all.
# Type: system spec (JavaScript). Not in the CI guard list; run locally.
# Why: the fit is measured, every change is saved into the view at once and the
#   frame reloads from the stored list; none of that exists in a request spec. A
#   tick that does not reach the table or the database, or a boundary that does
#   not appear when the detail opens, is only visible here.
RSpec.describe 'Column picker', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: admin_role, active: true) }
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:tickets) do
    ActsAsTenant.with_tenant(organisation) do
      3.times.map { |i| create(:ticket, project: project, creator: user, title: "Spalten Ticket #{i + 1}") }
    end
  end
  let!(:view_configuration) do
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                                table_columns: %w[number title assignees created_at], header_columns: %w[assignees])
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  def stored_columns(view)
    ActsAsTenant.with_tenant(organisation) { view.reload.ordered_columns }
  end

  def ticket_folder(name:, owner:, columns: nil, shared_with: nil, can_edit: false)
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, name: name, organisation: organisation, project: project, user: owner,
                                     target_object_type: 'Ticket',
                                     display_columns: (columns ? { 'table_columns' => columns } : nil))
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Spalten')
      create(:smart_folder_share, smart_folder: folder, user: shared_with, can_edit: can_edit) if shared_with
      folder
    end
  end

  it 'opens from the header, ticks a field into the table and the base view at once, moves it by keyboard and closes on Escape' do
    visit organisation_project_tickets_path(organisation, project)
    expect(page).to have_css('table[data-fit]', wait: 5)
    expect(page).to have_no_css('#column-picker', visible: :visible)

    find('[data-column-picker-trigger]').click
    expect(page).to have_css('#column-picker', visible: :visible, wait: 5)
    expect(page).to have_css('.layout.column-picker-open')
    # The slide: the entering picture lasts one frame on open, then the panel eases in.
    expect(page).to have_no_css('.layout.column-picker-entering', wait: 2)
    expect(page).to have_css('[data-column-picker-trigger][aria-expanded="true"]')

    # Tick "Tags": saved into the base view at once, the table gets the column as rank 3,
    # and it comes in tinted, the pointer still resting on its row.
    find('#column-picker li[data-key="tags"] label').click
    expect(page).to have_css('th.column-highlight[data-rank="3"][data-col-min="140"]', wait: 5)
    expect(stored_columns(view_configuration)).to eq(%w[number title assignees created_at tags])
    # No draft anywhere: no dot on the tab, no save row, nothing in the address.
    expect(page).not_to have_css('a[role="tab"][aria-selected="true"] [data-filter-bar-target="unsavedDot"]', visible: :visible)
    expect(page).to have_no_css('[data-filter-bar-target="saveRow"]', visible: :visible)
    expect(page.current_url).not_to include('cols')

    # Alt+Up twice: Tags becomes rank 1 in the panel, the table and the base view.
    row = find('#column-picker li[data-key="tags"]')
    row.find('.column-picker__grip').click
    row.send_keys(%i[alt up])
    row.send_keys(%i[alt up])
    expect(page).to have_css('th[data-rank="1"][data-col-min="140"]', wait: 5)
    expect(page.all('#column-picker li.column-picker__row[data-key]').first['data-key']).to eq('tags')
    expect(stored_columns(view_configuration)).to eq(%w[number title tags assignees created_at])

    # Pointing at a row tints its column in the table; leaving it clears the tint.
    find('#column-picker li[data-key="assignees"]').hover
    expect(page).to have_css('th.column-highlight[data-column="assignees"]', wait: 2)
    expect(page).to have_css('td.column-highlight[data-column="assignees"]', minimum: 1)
    find('#column-picker h2').hover
    expect(page).to have_no_css('.column-highlight', wait: 2)

    # Escape closes; the table keeps what was saved.
    find('body').send_keys(:escape)
    expect(page).to have_no_css('#column-picker', visible: :visible, wait: 5)
    expect(page).to have_no_css('.layout.column-picker-open')
    expect(page).to have_css('th[data-rank="1"][data-col-min="140"]')
  end

  it 'saves into the active view when one is open, and leaves the base view alone' do
    folder = ticket_folder(name: 'Spalten-Ansicht', owner: user, columns: %w[number title created_at])
    visit organisation_project_tickets_path(organisation, project, smart_folder_id: folder.id)
    expect(page).to have_css('th[data-rank="1"][data-col-min="110"]', wait: 5) # created_at, the folder's own list

    find('[data-column-picker-trigger]').click
    find('#column-picker li[data-key="assignees"] label', wait: 5).click
    expect(page).to have_css('th[data-rank="2"][data-col-min="120"]', wait: 5)

    expect(stored_columns(folder)).to eq(%w[number title created_at assignees])
    expect(stored_columns(view_configuration)).to eq(%w[number title assignees created_at])
    expect(page).to have_css('.column-picker__foot strong', text: 'Spalten-Ansicht')
  end

  it 'shows a read-only shared view without taking a tick' do
    # A plain member with ticket access: an account admin may update any folder.
    ActsAsTenant.with_tenant(organisation) do
      membership.update!(role: create(:role, organisation: organisation, title: 'member'))
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
    end
    colleague = ActsAsTenant.with_tenant(organisation) do
      c = create(:user)
      create(:membership, user: c, organisation: organisation, role: admin_role, active: true)
      c
    end
    folder = ticket_folder(name: 'Fremde Ansicht', owner: colleague, columns: %w[number title created_at], shared_with: user, can_edit: false)
    visit organisation_project_tickets_path(organisation, project, smart_folder_id: folder.id)

    find('[data-column-picker-trigger]', wait: 5).click
    expect(page).to have_css('#column-picker', visible: :visible, wait: 5)
    expect(page).to have_text('nur lesbar')
    expect(page).to have_css('#column-picker li[data-key="assignees"] input[disabled]')

    find('#column-picker li[data-key="assignees"] label').click
    sleep 0.5
    expect(stored_columns(folder)).to eq(%w[number title created_at])
    expect(page).to have_no_css('th[data-rank="2"]')
  end

  # S5, the exception: the list as it stands goes into the base view and every
  # own ticket view of the project at once; the page comes back with the count.
  it 'applies the list to all own views from the footer link and says how many took it' do
    own_view = ticket_folder(name: 'Meine Ansicht', owner: user, columns: %w[number title created_at])
    visit organisation_project_tickets_path(organisation, project)
    find('[data-column-picker-trigger]', wait: 5).click
    find('#column-picker li[data-key="tags"] label', wait: 5).click
    expect(page).to have_css('th[data-rank="3"][data-col-min="140"]', wait: 5)

    within('#column-picker') { click_on 'für alle Ansichten übernehmen' }

    expect(page).to have_css('[data-controller="neo-flash"]', text: 'Spalten für 2 Ansichten übernommen.', wait: 5)
    expect(stored_columns(view_configuration)).to eq(%w[number title assignees created_at tags])
    expect(stored_columns(own_view)).to eq(%w[number title assignees created_at tags])
    expect(page).to have_css('th[data-rank="3"][data-col-min="140"]')
  end

  it 'draws the boundary line once the detail is open and the width runs out' do
    # Four ranked columns (480 px of minimum widths) cannot all fit next to an
    # open detail, whatever the window: the boundary must appear.
    ActsAsTenant.with_tenant(organisation) { view_configuration.update!(ordered_columns: %w[number title assignees created_at updated_at tags]) }
    visit organisation_project_tickets_path(organisation, project, ticket_id: tickets.first.id)
    expect(page).to have_css('.layout.two-column:not(.hide-content)', wait: 5)

    find('[data-column-picker-trigger]').click
    expect(page).to have_css('#column-picker', visible: :visible, wait: 5)
    # Floating over the detail: the list keeps its width, the grid keeps its tracks.
    expect(page).to have_no_css('.layout.hide-content.column-picker-open')
    expect(page).to have_css('#column-picker li[role="separator"]', visible: :visible, wait: 5)
    fit = page.find('table[data-fit]')['data-fit'].to_i
    expect(fit).to be < 4
    # The separator sits before the first ticked row beyond the fit.
    items = page.all('#column-picker ul > li[data-key], #column-picker ul > li[role="separator"]', visible: :all).map { |li| li['role'] == 'separator' ? 'separator' : li['data-key'] }
    expect(items.index('separator')).to eq(fit)

    # Floating, the panel sits 10 px past the list's edge, not at the window's
    # edge: it is about the list. Layout positions, not bounding rects: the
    # panel is still easing in (a transform) when this is measured, and the
    # offset is what the controller set. Both in viewport coordinates: the panel
    # is position: fixed, and the list's offsetLeft counts from the lane layout
    # (#730), not from the viewport.
    gap = page.evaluate_script("(() => { const p = document.getElementById('column-picker'); const l = document.querySelector('.column.list'); return p.offsetLeft - l.getBoundingClientRect().right })()")
    expect(gap).to be_within(2).of(10)
    # Since 20a (S2) the trigger sits in the filter bar, so the header row ends
    # with the last column that shows something and the table keeps its title.
    # Narrow, the trigger's count yields and its icon stays.
    expect(page).to have_no_css('th.column-picker-trigger-cell', visible: :all)
    expect(page).to have_css('[data-fb-view-tool] [data-column-picker-trigger]')
    # The count left the button with the lane (#730) and lives in its title,
    # so it survives the open detail whatever the width.
    expect(find('[data-fb-view-tool] [data-column-picker-trigger]')['title'])
      .to eq(I18n.t('components.column_picker.trigger_title', count: 6))
    expect(page.evaluate_script("document.querySelector('td.title-column').offsetWidth")).to be >= 150
    # A rank beyond the fit is a 0 px column next to an open detail, not a
    # blank gap of its minimum width (the bug of 07.09.: two important widths).
    hidden = page.evaluate_script("Array.from(document.querySelectorAll('th[data-rank]')).filter(th => Number(th.dataset.rank) > #{fit}).map(th => th.offsetWidth)")
    expect(hidden).to all(eq(0))

    # More columns than fit, ticked while the detail is open: the list reloads
    # from a stream, the new table is measured again, the title keeps its room
    # (the bug of 07.09.: the title vanished behind six fixed widths).
    find('#column-picker li[data-key="time_spent"] label').click
    expect(page).to have_css('th[data-rank="5"]', visible: :all, wait: 5)
    sleep 0.3
    expect(page.evaluate_script("document.querySelector('td.title-column').offsetWidth")).to be >= 150
    fit_after = page.find('table[data-fit]')['data-fit'].to_i
    hidden_after = page.evaluate_script("Array.from(document.querySelectorAll('th[data-rank]')).filter(th => Number(th.dataset.rank) > #{fit_after}).map(th => th.offsetWidth)")
    expect(hidden_after).to all(eq(0))
  end
end
