# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meeting filters and columns', type: :system do
  before { Prosopite.pause }
  after do
    Prosopite.resume
    page.driver.browser.manage.window.resize_to(1920, 1080)
  end
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end
  let!(:meetings) do
    ActsAsTenant.with_tenant(organisation) do
      %w[Alpha Beta Gamma].map do |title|
        meeting = create(:meeting, project: project, organisation: organisation, creator: user, title: title, notes: 'Shared needle')
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: title == 'Gamma' ? 'Bert' : 'Anna')
        meeting
      end
    end
  end
  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  def path(**state)
    organisation_project_meetings_path(organisation, project, **state)
  end

  it 'saves a participant view, changes its columns and reopens its expert editor without leaving the list' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit path(filter: { participant: ['Anna'] }, search: 'a', search_mode: 'title_only')
    expect(page).to have_css('[data-fb-hits-total="2"]')
    click_button 'Als Ansicht sichern'
    fill_in 'smart_folder_name', with: 'Mit Anna'
    click_button 'Sichern'
    expect(page).to have_css('[role="tab"][aria-selected="true"]', text: 'Mit Anna')
    expect(find('input[name="search"]').value).to eq('a')
    expect(page).to have_current_path(/search_mode=title_only/)
    find('[data-column-picker-trigger]').click
    find('#column-picker li[data-key="creator"] label').click
    expect(page).to have_css('th[data-column="creator"]', visible: :all)
    find('#column-picker li[data-key="creator"] .column-picker__grip').click
    find('#column-picker li[data-key="creator"]').send_keys(%i[alt arrow_up])
    find('#column-picker [data-action="click->column-picker#close"]').click
    find('[data-filter-bar-target="viewMenuButton"]').click
    click_on 'Im Expertenfilter öffnen…'
    expect(page).to have_css('#modal [data-controller="smart-folder-modal"]')
    expect(page).to have_css('#modal input[name="list_context[search_mode]"][value="title_only"]', visible: :all)
    find('#modal select[name$="[operator]"]').select('hat alle Teilnehmer')
    expect(page).to have_css('#modal input[type="checkbox"][value="anna"]:checked')
    within('#modal') { click_button 'Speichern' }
    expect(page).to have_css('[data-fb-hits-total="2"]')
    expect(page).to have_no_css('#modal [data-controller="smart-folder-modal"]')
    expect(page).to have_current_path(/search_mode=title_only/)
    expect(page).to have_css('[data-filter-bar-dissolver-value*="\"participant\":\"and\""]')
    find('[data-filter-bar-target="viewMenuButton"]').click
    click_on 'Im Expertenfilter öffnen…'
    expect(page).to have_css('#modal [data-controller="smart-folder-modal"]')
    click_on 'Abbrechen'
    expect(page).to have_no_css('#modal [data-controller="smart-folder-modal"]')
    expect(page).to have_css('#meetings_results')
    page.refresh
    expect(page.all('thead th', visible: :all).map { |e| e['data-column'] }).to eq(%w[title occurred_at duration_minutes creator participants])
    visit path
    expect(page.all('thead th', visible: :all).map { |e| e['data-column'] }).to eq(%w[title occurred_at duration_minutes participants])
  end

  it 'follows sorting, pagination and saved-view links with their intended state' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    folder = create(:smart_folder, name: 'Weitere Ansicht', user: user, organisation: organisation,
                                   project: project, target_object_type: 'Meeting')
    visit path(items: 2, sort: { column: 'title', direction: 'asc' })
    expect(page).to have_css('tr[data-meeting-id]', count: 2)
    find('.pagination-container-compact a[title="Nächste Seite"]').click
    expect(page).to have_css('tr[data-meeting-id]', count: 1)
    expect(page).to have_css('tr[data-meeting-id]', text: 'Gamma')
    expect(page).to have_current_path(/page=2/)
    find('th[data-column="title"] a').click
    expect(page).to have_css('tr[data-meeting-id]', count: 2)
    expect(page.all('tr[data-meeting-id] h5').map(&:text)).to eq(%w[Gamma Beta])
    expect(page).to have_current_path(/sort%5Bdirection%5D=desc/)
    find('[role="tab"]', text: 'Weitere Ansicht').click
    expect(page).to have_css('[role="tab"][aria-selected="true"]', text: 'Weitere Ansicht')
    expect(page).to have_current_path(/smart_folder_id=#{folder.id}/)
    find('[role="tab"]', text: 'Alle Meetings').click
    expect(page).to have_css('[role="tab"][aria-selected="true"]', text: 'Alle Meetings')
    expect(page).not_to have_current_path(/smart_folder_id=/)
  end

  it 'saves a meeting view after removing its final condition' do
    result = Actors::SaveSmartFolderFromFilters.call(project: project, current_user: user,
                                                     filter_params: { 'participant' => ['Anna'] }, operator_params: {},
                                                     name: 'Clearable', target_object_type: 'Meeting')
    expect(result).to be_success
    folder = result.resource
    visit path(smart_folder_id: folder.id)
    expect(page).to have_css('[data-fb-hits-total="2"]')
    find('[data-action="click->filter-bar#startEditing"]').click
    find('[data-condition="participant"] [data-fb-remove-condition]').click
    expect(page).to have_css('[data-fb-hits-total="3"]')
    click_button 'Änderung speichern'
    expect(page).to have_no_button('Änderung speichern')
    page.refresh
    expect(page).to have_css('[role="tab"][aria-selected="true"]', text: 'Clearable')
    expect(page).to have_css('[data-fb-hits-total="3"]')
    expect(folder.reload.smart_folder_rules).to be_empty
    find('[data-filter-bar-target="viewMenuButton"]').click
    click_on 'Im Expertenfilter öffnen…'
    expect(page).to have_css('#modal [data-controller="smart-folder-modal"]')
    within('#modal') { click_button 'Speichern' }
    expect(page).to have_no_css('#modal [data-controller="smart-folder-modal"]')
    expect(page).to have_css('[data-fb-hits-total="3"]')
    expect(folder.reload.smart_folder_rules).to be_empty
  end

  it 'retains nested filters through details, editing, save and history' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit path(filter: { participant: ['Anna'] }, items: 10, search_mode: 'title_only')
    find("tr[data-meeting-id='#{meetings.first.id}']").click
    expect(page).to have_css('#meeting-header', text: 'Alpha')
    find('#meeting-header a[title="Meeting bearbeiten"]').click
    expect(page).to have_field('meeting[title]', with: 'Alpha')
    expect(page).to have_css('#meeting_display_frame input[name="filter[participant][]"][value="Anna"]', visible: :all)
    fill_in 'meeting[title]', with: 'Alpha updated'
    within('#meeting_display_frame') { click_button 'Speichern' }
    expect(page).to have_css('#meeting-header', text: 'Alpha updated')
    expect(page).to have_css('[data-fb-hits-total="2"]')
    find('#meeting-header [data-lane-close]').click
    expect(page).to have_no_css('#meeting-header')
    expect(page).to have_current_path(/participant/)
    page.go_back
    expect(page).to have_css('#meeting-header', text: 'Alpha updated')
    page.go_forward
    expect(page).to have_no_css('#meeting-header')
  end

  it 'offers the same saved columns on mobile and returns from details with the filters intact' do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit path(filter: { participant: ['Anna'] }, viewport: 'mobile')
    expect(page).to have_css('[data-fb-hits-total="2"]')
    expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be(true)
    find('[data-column-picker-trigger]').click
    expect(page).to have_css('#column-picker', visible: :visible)
    find('#column-picker li[data-key="creator"] label').click
    expect(page).to have_css('th[data-column="creator"]', visible: :all)
    find('#column-picker [data-action="click->column-picker#close"]').click
    find("tr[data-meeting-id='#{meetings.first.id}']").click
    expect(page).to have_css('#meeting-header', text: 'Alpha')
    click_on 'Zur Liste', match: :first
    expect(page).to have_css('[data-fb-hits-total="2"]')
    expect(page).to have_current_path(/participant/)
  end

  it 'enters the rows from the search field and opens a meeting with the keyboard' do
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit path(search: 'a', search_mode: 'title_only')
    expect(page).to have_css('[data-fb-hits-total="3"]')
    find('input[name="search"]').send_keys(:arrow_down)
    row = find('tr[data-meeting-id]:focus')
    expect(row).to eq(first('tr[data-meeting-id]'))
    title = row.find('h5').text
    row.send_keys(:enter)
    expect(page).to have_css('#meeting-header', text: title)
  end
end
