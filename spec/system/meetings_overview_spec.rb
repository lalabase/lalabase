# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" in the browser (doc/meetings_uebersicht_vereinheitlichen_plan.md,
# PR 1 to 3): the shared filter bar with the condition "Projekt", a view saved
# on this page and opened again, the "+" modal, whose save must leave the list
# with the conditions it had, the column picker, and the meeting in the lane,
# whose saves redraw this list. The request specs cannot see these: the modal
# reads the list state from the list frame in JavaScript, the picker saves and
# reloads the frame from the browser, and the lane is opened, closed and
# restored by the row opener, the ✕ and Back.
RSpec.describe 'Meetings overview', type: :system do
  before { Prosopite.pause }
  after do
    Prosopite.resume
    page.driver.browser.manage.window.resize_to(1920, 1080)
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:alpha) { create(:project, organisation: organisation, name: 'Projekt Alpha') }
  let(:beta) { create(:project, organisation: organisation, name: 'Projekt Beta') }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: alpha, organisation: organisation, creator: user, title: 'Alpha Kickoff', occurred_at: 2.days.ago)
      create(:meeting, project: beta, organisation: organisation, creator: user, title: 'Beta Retro', occurred_at: 1.day.ago)
    end
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  def expect_titles(*titles)
    titles.each { |title| expect(page).to have_css('#meetings_overview_results tr[data-meeting-id]', text: title, wait: 5) }
    expect(page).to have_css('#meetings_overview_results tr[data-meeting-id]', count: titles.size, wait: 5)
  end

  it 'filters by project through "+ Filter", saves the view and opens it again' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit organisation_meetings_path(organisation)
    expect_titles('Alpha Kickoff', 'Beta Retro')

    find('[data-filter-bar-target="filterButton"]').click
    find('[role="menuitem"][data-category="project"]').click
    within('[data-filter-bar-target="valueMenu"]') { find("input[type='checkbox'][data-filter-value='#{alpha.id}']").click }
    expect_titles('Alpha Kickoff')
    page.send_keys(:escape)
    page.send_keys(:escape)

    click_button 'Als Ansicht sichern'
    fill_in 'smart_folder_name', with: 'Nur Alpha'
    click_button 'Sichern'
    expect(page).to have_css('[role="tab"][aria-selected="true"]', text: 'Nur Alpha', wait: 5)
    expect_titles('Alpha Kickoff')
    saved = SmartFolder.find_by!(name: 'Nur Alpha')
    expect(saved.project_id).to be_nil

    visit organisation_meetings_path(organisation)
    expect_titles('Alpha Kickoff', 'Beta Retro')
    find('[role="tab"]', text: 'Nur Alpha').click
    expect_titles('Alpha Kickoff')

    visit organisation_project_meetings_path(organisation, alpha)
    expect(page).to have_css('[role="tab"]', text: I18n.t('smart_folders.all_meetings'))
    expect(page).to have_no_css('[role="tab"]', text: 'Nur Alpha')
  end

  it 'keeps the conditions of the list after a save from the "+" modal' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit organisation_meetings_path(organisation, filter: { project: [alpha.id] })
    expect_titles('Alpha Kickoff')

    find("button[title='#{I18n.t('views.organisations.meetings_overview.index.new_meeting')}']").click
    select 'Projekt Alpha', from: 'meeting-modal-project'
    within('#meeting_modal_form') do
      fill_in 'meeting[title]', with: 'Alpha Planung'
      click_button I18n.t('views.organisations.meetings.form.save')
    end

    expect(page).to have_no_css('[data-meeting-modal-target="modal"]:not(.hidden)', wait: 5)
    expect_titles('Alpha Planung', 'Alpha Kickoff')
    expect(page).to have_current_path(/filter%5Bproject%5D/)
  end

  it 'keeps a sort chosen at a column head through a new condition and a reload' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: alpha, organisation: organisation, creator: user, title: 'Aaa Alpha', occurred_at: 5.days.ago)
    end
    visit organisation_meetings_path(organisation)
    expect_titles('Beta Retro', 'Alpha Kickoff', 'Aaa Alpha')

    find('#meetings_overview_results th[data-column="title"] a').click
    expect(page).to have_current_path(/sort%5Bcolumn%5D=title/, wait: 5)

    find('[data-filter-bar-target="filterButton"]').click
    find('[role="menuitem"][data-category="project"]').click
    within('[data-filter-bar-target="valueMenu"]') { find("input[type='checkbox'][data-filter-value='#{alpha.id}']").click }
    expect_titles('Aaa Alpha', 'Alpha Kickoff')
    expect(page.all('#meetings_overview_results tr[data-meeting-id] h5').map { |title| title.text.strip }).to eq(['Aaa Alpha', 'Alpha Kickoff'])
    expect(page).to have_current_path(/sort%5Bcolumn%5D=title/)

    page.refresh
    expect(page.all('#meetings_overview_results tr[data-meeting-id] h5', wait: 5).map { |title| title.text.strip }).to eq(['Aaa Alpha', 'Alpha Kickoff'])
  end

  def head_keys
    page.all('#meetings_overview_results thead th').map { |head| head['data-column'] }
  end

  def overview_columns
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.find_by(user: user, organisation: organisation, project: nil, view_type: 'meetings')&.ordered_columns
    end
  end

  # PR 2: the project page's column picker, with the column "Projekt" only here.
  it 'ticks, unticks and moves a column, saves at once and keeps the order through a reload' do
    page.driver.browser.manage.window.resize_to(1920, 1080)
    visit organisation_meetings_path(organisation)
    expect_titles('Alpha Kickoff', 'Beta Retro')
    expect(head_keys).to eq(%w[title project occurred_at duration_minutes participants])

    find('[data-column-picker-trigger]').click
    expect(page).to have_css('#column-picker', visible: :visible, wait: 5)
    expect(page).to have_css('#column-picker li[data-key="project"]')

    find('#column-picker li[data-key="creator"] label').click
    expect(page).to have_css('#meetings_overview_results th[data-column="creator"][data-rank="5"]', wait: 5)

    # Two places up, above participants and duration.
    row = find('#column-picker li[data-key="creator"]')
    row.find('.column-picker__grip').click
    row.send_keys(%i[alt up])
    row.send_keys(%i[alt up])
    expect(page).to have_css('#meetings_overview_results th[data-column="creator"][data-rank="3"]', wait: 5)

    find('#column-picker li[data-key="duration_minutes"] label').click
    expect(page).to have_no_css('#meetings_overview_results th[data-column="duration_minutes"]', wait: 5)
    expect(overview_columns).to eq(%w[title project occurred_at creator participants])

    page.refresh
    expect(page).to have_css('#meetings_overview_results th[data-column="creator"]', wait: 5)
    expect(head_keys).to eq(%w[title project occurred_at creator participants])

    visit organisation_project_meetings_path(organisation, alpha)
    find('[data-column-picker-trigger]').click
    expect(page).to have_css('#column-picker li[data-key="creator"]', visible: :visible, wait: 5)
    expect(page).to have_no_css('#column-picker li[data-key="project"]')
    expect(page).to have_no_css('table th[data-column="creator"]')
  end

  it 'fits a phone of 390 px without scrolling sideways, the project under each title' do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit organisation_meetings_path(organisation)

    expect(page).to have_css('#meetings_overview_results tr[data-meeting-id]', count: 2, wait: 10)
    expect(page).to have_css('[data-controller="filter-bar"] [data-column-picker-trigger]')
    expect(page).to have_css('#meetings_overview_results tr[data-meeting-id] .ticket-meta__item', text: 'Projekt Alpha')
    overflow = page.evaluate_script('document.documentElement.scrollWidth - document.documentElement.clientWidth')
    expect(overflow).to be <= 0
    list_overflow = page.evaluate_script(
      "(function(){ var box = document.querySelector('#meetings_overview_results table').parentElement; return box.scrollWidth - box.clientWidth })()"
    )
    expect(list_overflow).to be <= 0
  end

  describe 'the lane' do
    let(:overview_rows) { '#meetings_overview_results tr[data-meeting-id]' }

    def meeting(title) = Meeting.unscoped.find_by!(title: title)

    def row_of(title) = find(overview_rows, text: title)

    def lane_title = find('#meeting_display_frame h2', wait: 5)

    before do
      ActsAsTenant.with_tenant(organisation) do
        ['Alpha Kickoff', 'Beta Retro'].each do |title|
          create(:meeting_participant, meeting: Meeting.find_by!(title: title), display_name: 'Anna')
        end
        create(:meeting, project: alpha, organisation: organisation, creator: user, title: 'Alpha Ohne Anna', occurred_at: 3.days.ago)
      end
    end

    it 'opens a row beside the list, saves in it and keeps the list with its condition' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, filter: { participant: ['Anna'] })
      expect_titles('Alpha Kickoff', 'Beta Retro')

      row_of('Beta Retro').click
      expect(lane_title).to have_text('Beta Retro')
      expect(page).to have_css("#{overview_rows}.selected-row", text: 'Beta Retro')
      expect(page).to have_current_path(/meeting_id=#{meeting('Beta Retro').id}/)
      expect(page).to have_current_path(/filter%5Bparticipant%5D/)

      within('#meeting_display_frame') { find("a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']", match: :first).click }
      within('#meeting_display_frame') do
        fill_in 'meeting[title]', with: 'Beta Retro neu'
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_display_frame h2', text: 'Beta Retro neu', wait: 5)
      expect_titles('Alpha Kickoff', 'Beta Retro neu')
      expect(page).to have_css("#{overview_rows}.selected-row", text: 'Beta Retro neu')
      expect(page).to have_current_path(/filter%5Bparticipant%5D/)
      expect(page).to have_current_path(/meeting_id=/)
    end

    it 'keeps a condition set beside the open lane through a save in it' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      expect_titles('Alpha Kickoff', 'Beta Retro', 'Alpha Ohne Anna')
      row_of('Alpha Kickoff').click
      expect(lane_title).to have_text('Alpha Kickoff')

      find('[data-filter-bar-target="filterButton"]').click
      find('[role="menuitem"][data-category="project"]').click
      within('[data-filter-bar-target="valueMenu"]') { find("input[type='checkbox'][data-filter-value='#{alpha.id}']").click }
      expect_titles('Alpha Kickoff', 'Alpha Ohne Anna')
      # A click beside the menu closes it. Escape would close the lane too while
      # the value menu is open, on the project page as well (not this PR's).
      find('#meeting_display_frame h2').click
      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff')

      within('#meeting_display_frame') { find("a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']", match: :first).click }
      within('#meeting_display_frame') do
        fill_in 'meeting[title]', with: 'Alpha Kickoff neu'
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff neu', wait: 5)
      expect_titles('Alpha Kickoff neu', 'Alpha Ohne Anna')
    end

    it 'closes with the ✕, and Back and Forward open and close the lane' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, search: 'Alpha')
      expect_titles('Alpha Kickoff', 'Alpha Ohne Anna')

      row_of('Alpha Kickoff').click
      expect(lane_title).to have_text('Alpha Kickoff')
      find('#meeting_display_frame [data-lane-close]').click
      expect(page).to have_no_css('#meeting_display_frame h2', wait: 5)
      expect(page).to have_no_current_path(/meeting_id=/, wait: 5)
      expect(page).to have_current_path(/search=Alpha/)

      page.go_back
      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff', wait: 5)
      expect(page).to have_current_path(/meeting_id=#{meeting('Alpha Kickoff').id}/)
      page.go_back
      expect(page).to have_no_css('#meeting_display_frame h2', wait: 5)
      expect(page).to have_no_current_path(/meeting_id=/)
      page.go_forward
      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff', wait: 5)
      expect_titles('Alpha Kickoff', 'Alpha Ohne Anna')
    end

    it 'deletes from the lane: the lane closes and the meeting leaves the list' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, meeting_id: meeting('Beta Retro').id)
      expect(lane_title).to have_text('Beta Retro')

      within('#meeting_display_frame') { find("a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']", match: :first).click }
      accept_confirm { within('#meeting_display_frame') { click_button I18n.t('views.organisations.meetings.form.delete') } }

      expect_titles('Alpha Kickoff', 'Alpha Ohne Anna')
      expect(page).to have_no_css('#meeting_display_frame h2', wait: 5)
      expect(page).to have_no_current_path(/meeting_id=/, wait: 5)
      expect(page).to have_no_css('.labor-layout-view.show-content')
    end

    it 'enters the rows from the search field and opens a meeting with the keyboard' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      # A search value keeps the field open, as in the project page's spec.
      visit organisation_meetings_path(organisation, search: 'a', search_mode: 'title_only')
      expect(page).to have_css(overview_rows, count: 3, wait: 10)

      # No click first: the rows hold no link of their own (tabindex -1), so
      # the search field is the one way in, as on the project page.
      # The scripts load after the rows show: an arrow pressed before the
      # keyboard controller listens does nothing, so it is pressed again.
      search = find('input[name="search"]')
      page.document.synchronize(5) do
        search.send_keys(:arrow_down)
        raise Capybara::ElementNotFound, 'no row has focus yet' unless page.has_css?("#{overview_rows}:focus", wait: 0.2)
      end
      row = find("#{overview_rows}:focus")
      expect(row).to eq(first(overview_rows))
      row.send_keys(:arrow_down)
      row = find("#{overview_rows}:focus")
      expect(row).to have_text('Alpha Kickoff')
      row.send_keys(:enter)
      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff', wait: 5)
      expect(page).to have_css("#{overview_rows}.selected-row", text: 'Alpha Kickoff')
    end

    it 'leaves the open lane and its unsaved edit alone when Escape closes the "+" modal' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      expect_titles('Alpha Kickoff', 'Beta Retro', 'Alpha Ohne Anna')
      row_of('Beta Retro').click
      expect(lane_title).to have_text('Beta Retro')
      within('#meeting_display_frame') { find("a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']", match: :first).click }
      within('#meeting_display_frame') { fill_in 'meeting[title]', with: 'Ungespeichert' }

      find("button[title='#{I18n.t('views.organisations.meetings_overview.index.new_meeting')}']").click
      expect(page).to have_css('[data-meeting-modal-target="modal"]:not(.hidden)', wait: 5)
      page.send_keys(:escape)

      expect(page).to have_no_css('[data-meeting-modal-target="modal"]:not(.hidden)', wait: 5)
      expect(page).to have_css('.labor-layout-view.show-content')
      expect(find('#meeting_display_frame').find_field('meeting[title]').value).to eq('Ungespeichert')
      expect(page).to have_current_path(/meeting_id=#{meeting('Beta Retro').id}/)
    end

    it 'opens the meeting full width on a phone and leads back to the list with its search' do
      page.driver.browser.manage.window.resize_to(390, 844)
      visit organisation_meetings_path(organisation, search: 'Alpha')
      expect(page).to have_css(overview_rows, count: 2, wait: 10)

      row_of('Alpha Kickoff').click
      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff', wait: 10)
      expect(page).to have_no_css(overview_rows)
      overflow = page.evaluate_script('document.documentElement.scrollWidth - document.documentElement.clientWidth')
      expect(overflow).to be <= 0

      find('.mobile-ticket-view a', text: I18n.t('views.organisations.meetings.index.mobile_list_view'), match: :first).click
      expect(page).to have_css(overview_rows, count: 2, wait: 10)
      expect(page).to have_current_path(/search=Alpha/)
      expect(page).to have_no_current_path(/meeting_id=/)
    end
  end
end
