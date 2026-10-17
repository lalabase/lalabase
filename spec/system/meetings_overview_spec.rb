# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" in the browser (doc/meetings_uebersicht_vereinheitlichen_plan.md,
# PR 1): the shared filter bar with the condition "Projekt", a view saved on
# this page and opened again, and the "+" modal, whose save must leave the list
# with the conditions it had. The request specs cannot see the last one: the
# modal reads the list state from the list frame in JavaScript.
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

  it 'fits a phone of 390 px without scrolling sideways' do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit organisation_meetings_path(organisation)

    expect(page).to have_css('#meetings_overview_results li[data-meeting-id]', count: 2, wait: 10)
    expect(page).to have_css('[data-controller="filter-bar"]')
    overflow = page.evaluate_script('document.documentElement.scrollWidth - document.documentElement.clientWidth')
    expect(overflow).to be <= 0
  end
end
