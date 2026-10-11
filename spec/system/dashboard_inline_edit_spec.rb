# frozen_string_literal: true

require 'rails_helper'

# End-to-end for the inline WYSIWYG dashboard editor (auto-columns / split-pane model).
#
# The reindex test (the #1 bug risk, §11.1/§14) is the load-bearing one: a row with TWO
# settings-bearing widgets carrying DIFFERENT settings is reordered, and each widget must keep its
# OWN settings after save. A partial reindex (rewriting only rows[i], not [widgets][j]) would
# mismatch settings — a single widget would never reveal it.
#
# Reordering / resizing is driven through the ⋯-menu chips (the keyboard/touch path, WCAG 2.5.7),
# which is deterministic (no flaky native drag) AND exercises the same reindex-on-submit + width
# code a mouse drag does. Cross-row DRAG is intentionally not covered here (native Selenium drag is
# flaky); it is verified manually. NOTE: a row no longer has a "type" — widths are 1/6-of-a-row
# units and a row always fills to ROW_UNITS.
RSpec.describe 'Dashboard inline edit', type: :system do
  before do
    Prosopite.pause
    driven_by(:selenium_chrome_headless_full) # CSS-faithful so .hidden menus behave
  end
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  def seed_config(layout)
    ActsAsTenant.with_tenant(organisation) do
      DashboardConfiguration.create!(user: user, project: project, organisation: organisation, layout: layout)
    end
  end

  def saved_layout
    ActsAsTenant.with_tenant(organisation) do
      DashboardConfiguration.find_by(user: user, project: project)&.layout
    end
  end

  def enter_edit_mode
    visit organisation_project_path(organisation, project)
    find("a[href$='dashboard_configuration/edit']").click
    expect(page).to have_css("[data-controller='dashboard-inline-edit']")
  end

  before { sign_in user }

  it 'reorders two settings-bearing widgets within a row and keeps each its own settings' do
    seed_config([{ 'widgets' => [
                  { 'key' => 'recent_tickets', 'display' => 'list',  'period' => 'this_week' },
                  { 'key' => 'recent_tickets', 'display' => 'cards', 'period' => 'this_month' }
                ] }])

    enter_edit_mode

    # Move the first widget RIGHT (within-row reorder via the ⋯ menu — the keyboard path).
    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      click_button I18n.t('dashboard.configuration.move_right')
    end

    click_button I18n.t('dashboard.configuration.save')
    expect(page).to have_css("a[href$='dashboard_configuration/edit']") # back in view mode

    widgets = saved_layout.first['widgets']
    expect(widgets[0]).to include('period' => 'this_month', 'display' => 'cards')
    expect(widgets[1]).to include('period' => 'this_week',  'display' => 'list')
  end

  it 'persists a per-widget setting change' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets', 'period' => 'all_time', 'display' => 'list' }] }])

    enter_edit_mode

    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      find("select[data-name-suffix='[period]'] option[value='this_month']").select_option
    end

    click_button I18n.t('dashboard.configuration.save')
    expect(page).to have_css("a[href$='dashboard_configuration/edit']")

    expect(saved_layout.first['widgets'].first).to include('period' => 'this_month')
  end

  it 'warns about unsaved changes when leaving after an edit' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }])

    enter_edit_mode

    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      click_button I18n.t('dashboard.configuration.move_right')
    end

    # Dirty -> Cancel must raise the unsaved-changes confirm before the frame swap (§21.3).
    accept_confirm { click_link I18n.t('dashboard.configuration.cancel') }

    expect(page).to have_css("a[href$='dashboard_configuration/edit']")
    # nothing was persisted (we cancelled)
    expect(saved_layout.first['widgets'].map { |w| w['key'] }).to eq(%w[recent_tickets recent_notes])
  end

  # --- Empty-state guards (block, not silently revert to default) ---

  it 'blocks saving an empty dashboard and keeps the user in edit mode without reverting' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }] }])

    enter_edit_mode
    within first('[data-row]') do
      find("[data-action='click->dashboard-inline-edit#removeRow']").click # remove the only row
    end
    click_button I18n.t('dashboard.configuration.save')

    expect(page).to have_content(I18n.t('dashboard.configuration.empty_rows_error'))
    expect(page).to have_css("[data-controller='dashboard-inline-edit']") # no frame swap -> still editing
    # The stored config is untouched: the empty save was blocked, not persisted-and-reverted.
    expect(saved_layout.first['widgets'].compact.map { |w| w['key'] }).to eq(['recent_tickets'])
  end

  it 'blocks saving a stats_cards widget with no cards selected' do
    seed_config([{ 'widgets' => [{ 'key' => 'stats_cards', 'cards' => [{ 'key' => 'tickets' }] }] }])

    enter_edit_mode
    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      find("input[data-name-suffix='[card_keys][]'][value='tickets']").click # uncheck the only card
    end
    click_button I18n.t('dashboard.configuration.save')

    expect(page).to have_content(I18n.t('dashboard.configuration.empty_cards_error'))
    expect(page).to have_css("[data-controller='dashboard-inline-edit']") # still editing, not saved
  end

  # --- Width (units) via the ⋯-menu chips + the right-edge pointer drag ---

  it 'widens a widget by taking a unit from its neighbour and persists the width' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }]) # fills the row 3 + 3

    enter_edit_mode
    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      click_button I18n.t('dashboard.configuration.widen_width')
    end

    click_button I18n.t('dashboard.configuration.save')
    expect(page).to have_css("a[href$='dashboard_configuration/edit']")

    # recent_tickets grew to 4 (stored, > its minimum); recent_notes shrank to its minimum 2 (not stored).
    expect(saved_layout.first['widgets'].first).to include('key' => 'recent_tickets', 'units' => 4)
  end

  it 'widens a widget via a right-edge pointer drag' do
    # Exercises the actual drag handler (startResize -> setUnits), not just the menu path. A synthetic
    # PointerEvent sequence is deterministic where native Selenium pointer input is flaky.
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }])

    enter_edit_mode
    page.execute_script(<<~JS)
      const handle = document.querySelector('[data-slot] [data-slot-resize]');
      const slots = handle.closest('[data-slots]');
      const startX = handle.getBoundingClientRect().left;
      const endX = slots.getBoundingClientRect().right; // drag far right -> grows until the neighbour hits its min
      const at = (x) => ({ bubbles: true, clientX: x, pointerId: 1 });
      handle.dispatchEvent(new PointerEvent('pointerdown', at(startX)));
      handle.dispatchEvent(new PointerEvent('pointermove', at(endX)));
      handle.dispatchEvent(new PointerEvent('pointerup', at(endX)));
    JS

    click_button I18n.t('dashboard.configuration.save')
    expect(page).to have_css("a[href$='dashboard_configuration/edit']")

    expect(saved_layout.first['widgets'].first).to include('key' => 'recent_tickets', 'units' => 4)
  end

  it 'narrows a widened widget back toward the default' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 4 }, { 'key' => 'recent_notes' }] }]) # 4 + 2

    enter_edit_mode
    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      click_button I18n.t('dashboard.configuration.narrow_width')
    end

    click_button I18n.t('dashboard.configuration.save')
    expect(page).to have_css("a[href$='dashboard_configuration/edit']")

    # 4 -> 3 (gives a unit to the neighbour, which goes 2 -> 3): both at 3, neither above its minimum
    # of 2... recent_tickets 3 > 2 is stored; the contract here is simply that it narrowed below 4.
    expect(saved_layout.first['widgets'].first['units']).to eq(3)
  end

  it 'disables the width controls in a single-widget row (nothing to trade with)' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }] }]) # fills the whole row alone

    enter_edit_mode
    within first('[data-slot]') { find('[data-slot-menu-button]').click }
    expect(page).to have_button(I18n.t('dashboard.configuration.widen_width'), disabled: true)
  end

  # --- Widget picker gating (§21.2): only widgets whose minimum still fits the row are enabled ---

  it 'disables picker widgets whose minimum does not fit the room left in the row' do
    # Σ minimums = 2 + 2 + 1 = 5 -> 1 unit of room: a 1-unit widget fits, a 2-unit one does not.
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }, { 'key' => 'stats_cards' }] }])

    enter_edit_mode
    within first('[data-row]') do
      find('[data-add-widget]').click
      expect(find("[data-pick='stats_cards']")).not_to be_disabled # min 1 fits the 1 unit left
      expect(find("[data-pick='recent_notes']")).to be_disabled    # min 2 does not
    end
  end

  # --- Undo ---

  it 'undoes a width change' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }]) # 3 + 3

    enter_edit_mode
    within first('[data-slot]') do
      find('[data-slot-menu-button]').click
      click_button I18n.t('dashboard.configuration.widen_width') # -> 4 + 2
    end
    expect(first('[data-slot]')['data-units']).to eq('4')

    find("[data-dashboard-inline-edit-target='undoBtn']").click
    expect(first('[data-slot]')['data-units']).to eq('3') # reverted
  end

  # --- Keyboard + focus management (WCAG 2.4.3, §5.5/§19.5) ---

  it 'opens the menu by keyboard and returns focus to the trigger on Escape' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }] }])

    enter_edit_mode
    first('[data-slot-menu-button]').send_keys(:enter) # open via keyboard (flips the card)

    expect(page).to have_css('[data-slot].is-flipped')
    # Focus moves into the flipped settings panel (the first focusable is its close button).
    expect(page.evaluate_script("!!document.activeElement.closest('[data-flip-back]')")).to be(true)

    page.driver.browser.action.send_keys(:escape).perform
    expect(page.evaluate_script("document.activeElement.hasAttribute('data-slot-menu-button')")).to be(true)
  end

  # --- Add row + reorder rows + reindex across rows ---

  it 'reindexes correctly after adding a row and reordering rows' do
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets', 'period' => 'this_week' }] }])

    enter_edit_mode
    click_button I18n.t('dashboard.configuration.add_row')
    new_row = all('[data-row]').last
    within new_row do
      find('[data-add-widget]').click
      find("[data-pick='recent_notes']").click
      find("[data-action='click->dashboard-inline-edit#moveRowUp']").click
    end

    click_button I18n.t('dashboard.configuration.save')
    expect(page).to have_css("a[href$='dashboard_configuration/edit']")

    layout = saved_layout
    expect(layout.length).to eq(2)
    expect(layout[0]['widgets'].compact.first['key']).to eq('recent_notes')
    expect(layout[1]['widgets'].compact.first).to include('key' => 'recent_tickets', 'period' => 'this_week')
  end

  # --- Apply-to-all: the org-wide destructive confirm (submit() window.confirm) ---

  it 'applies the default to ALL projects when the apply-to-all confirm is accepted' do
    other = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }] }])

    enter_edit_mode
    find("input[name='save_scope'][value='default_all']").click

    accept_confirm { click_button I18n.t('dashboard.configuration.save') }
    expect(page).to have_css("a[href$='dashboard_configuration/edit']") # saved -> back in view mode

    ActsAsTenant.with_tenant(organisation) do
      expect(DashboardConfiguration.find_by(user: nil, project: project)).to be_present
      expect(DashboardConfiguration.find_by(user: nil, project: other)).to be_present
    end
  end

  it 'persists nothing and stays in edit mode when the apply-to-all confirm is dismissed' do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    seed_config([{ 'widgets' => [{ 'key' => 'recent_tickets' }] }])

    enter_edit_mode
    find("input[name='save_scope'][value='default_all']").click

    dismiss_confirm { click_button I18n.t('dashboard.configuration.save') }

    expect(page).to have_css("[data-controller='dashboard-inline-edit']") # blocked -> still editing
    ActsAsTenant.with_tenant(organisation) do
      expect(DashboardConfiguration.where(user: nil)).to be_empty # no project default created anywhere
    end
  end
end
