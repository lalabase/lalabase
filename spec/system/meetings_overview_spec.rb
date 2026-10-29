# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" in the browser (doc/meetings_uebersicht_vereinheitlichen_plan.md,
# PR 1 to 4): the shared filter bar with the condition "Projekt", a view saved
# on this page and opened again, the "+" with its project select in the lane,
# whose save must leave the list with the conditions it had, the column picker,
# and the meeting in the lane, whose saves redraw this list. The request specs
# cannot see these: the "+" and the select load their frames in JavaScript, the
# picker saves and reloads the frame from the browser, and the lane is opened,
# closed and restored by the row opener, the ✕ and Back.
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

  describe 'the "+" in the lane' do
    let(:plus) { "a[title='#{I18n.t('views.organisations.meetings_overview.index.new_meeting')}']" }
    let(:select_label) { I18n.t('views.organisations.meetings_overview.new_meeting.project_label') }

    def open_new_meeting
      find(plus).click
      expect(page).to have_css('#meeting_display_frame #meeting-new-project', wait: 5)
    end

    # The settled page: while a frame renders, the scroll bar can come and go
    # for a moment, and the page is a scroll bar wider than its box.
    def expect_no_sideways_scroll
      page.document.synchronize(5) do
        overflow = page.evaluate_script('document.documentElement.scrollWidth - document.documentElement.clientWidth')
        raise Capybara::ExpectationNotMet, "the page scrolls #{overflow} px sideways" if overflow.positive?
      end
    end

    it 'opens the select in the lane, saves into the chosen project and opens the new meeting in the list it kept' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, filter: { project: [alpha.id] })
      expect_titles('Alpha Kickoff')

      open_new_meeting
      expect(page).to have_css('.labor-layout-view.show-content')
      expect(page).to have_current_path(/new=meeting/)
      expect(page).to have_current_path(/filter%5Bproject%5D/)
      expect_titles('Alpha Kickoff')

      select 'Projekt Alpha', from: select_label
      within('#meeting_new_form') do
        fill_in 'meeting[title]', with: 'Alpha Planung'
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Planung', wait: 5)
      expect(page).to have_no_css('#meeting-new-project')
      expect_titles('Alpha Planung', 'Alpha Kickoff')
      expect(page).to have_css('#meetings_overview_results tr.selected-row', text: 'Alpha Planung')
      saved = Meeting.unscoped.find_by!(title: 'Alpha Planung')
      expect(saved.project).to eq(alpha)
      expect(page).to have_current_path(/meeting_id=#{saved.id}/)
      expect(page).to have_no_current_path(/new=meeting/)
      expect(page).to have_current_path(/filter%5Bproject%5D/)
    end

    it 'says so when the new meeting is not in the filtered list, and keeps it open in the lane' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, filter: { project: [alpha.id] })
      expect_titles('Alpha Kickoff')

      open_new_meeting
      select 'Projekt Beta', from: select_label
      within('#meeting_new_form') do
        fill_in 'meeting[title]', with: 'Beta Planung'
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_display_frame h2', text: 'Beta Planung', wait: 5)
      expect(page).to have_text(I18n.t('flash.meetings.created_hidden_by_filter'))
      expect_titles('Alpha Kickoff')
    end

    it 'loads the form of another project when the choice changes, and nothing when it is cleared' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      open_new_meeting
      expect(page).to have_css('#meeting_new_form', text: I18n.t('views.organisations.meetings_overview.new_meeting.select_project_first'))

      select 'Projekt Alpha', from: select_label
      expect(page).to have_css("#meeting_new_form form[action$='/projects/#{alpha.id}/meetings.turbo_stream']", wait: 5)
      select 'Projekt Beta', from: select_label
      expect(page).to have_css("#meeting_new_form form[action$='/projects/#{beta.id}/meetings.turbo_stream']", wait: 5)

      select I18n.t('views.organisations.meetings_overview.new_meeting.project_prompt'), from: select_label
      expect(page).to have_no_css('#meeting_new_form form', wait: 5)
      expect(page).to have_css('#meeting_new_form', text: I18n.t('views.organisations.meetings_overview.new_meeting.select_project_first'))
    end

    # The right for Beta went while the select stayed open: its form answers with
    # a redirect, and frame-error only put its message on top of the form of
    # Alpha, which stood there under the name Beta and saved into Alpha.
    it 'leaves no form of the project chosen before when the next one is refused' do
      writer = create(:user)
      beta_permission = ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: 'Schreiber', organisation: organisation)
        create(:membership, user: writer, organisation: organisation, role: role, active: true)
        create(:project_permission, user: writer, project: alpha, meetings_access: 'read_write')
        create(:project_permission, user: writer, project: beta, meetings_access: 'read_write')
      end
      sign_in writer
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      open_new_meeting

      select 'Projekt Alpha', from: select_label
      expect(page).to have_css("#meeting_new_form form[action$='/projects/#{alpha.id}/meetings.turbo_stream']", wait: 5)
      ActsAsTenant.with_tenant(organisation) { beta_permission.update!(meetings_access: 'read_only') }
      select 'Projekt Beta', from: select_label

      expect(page).to have_css('#meeting_new_form .frame-error-message', wait: 5)
      expect(page).to have_no_css('#meeting_new_form form')
      expect(page).to have_select(select_label, selected: 'Projekt Beta')
    end

    # The last right to read meetings went while the page stayed open. The
    # lane got the start page without its frame, and Turbo left "Content
    # missing" in it; now the page goes where a full visit goes.
    it 'leaves the page for the start page when the last right went meanwhile' do
      writer = create(:user)
      permission = ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: 'Schreiber', organisation: organisation)
        create(:membership, user: writer, organisation: organisation, role: role, active: true)
        create(:project_permission, user: writer, project: alpha, meetings_access: 'read_write')
      end
      sign_in writer
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      expect_titles('Alpha Kickoff')

      ActsAsTenant.with_tenant(organisation) { permission.update!(meetings_access: 'no_access') }
      find(plus).click

      expect(page).to have_text(I18n.t('shared.errors.not_authorized'), wait: 10)
      expect(page).to have_no_current_path(organisation_meetings_path(organisation), ignore_query: true)
      expect(page).to have_no_css('#meetings_overview_results')
      expect(page).to have_no_text('Content missing')
    end

    # The "+" takes meeting_id out of the address: the meeting is no longer in
    # the lane, so its row may not stay marked.
    it 'takes the mark off the open row when the "+" opens the select' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      find('#meetings_overview_results tr[data-meeting-id]', text: 'Beta Retro').click
      expect(page).to have_css('#meetings_overview_results tr.selected-row', text: 'Beta Retro', wait: 5)
      expect(page).to have_css('#meeting_display_frame h2', text: 'Beta Retro', wait: 5)

      # The "+" moves with the list column while the lane opens.
      wait_until_still(plus)
      open_new_meeting

      expect(page).to have_no_css('#meetings_overview_results tr.selected-row')
      expect(page).to have_no_current_path(/meeting_id=/, url: true)
    end

    # The options carry the list state from when the lane opened; the live one
    # comes from the address at submit (layout-toggle, the form's
    # data-lane-index-url). A search typed beside the open form has to survive
    # the save.
    it 'keeps a search typed while the form is open through the save' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      # A search value keeps the field open, as in the keyboard example below.
      visit organisation_meetings_path(organisation, search: 'a', search_mode: 'title_only')
      expect_titles('Alpha Kickoff', 'Beta Retro')

      open_new_meeting
      select 'Projekt Alpha', from: select_label
      expect(page).to have_css('#meeting_new_form form', wait: 5)
      find('input[name="search"]').fill_in(with: 'Alpha')
      # The address moves once the list has reloaded; a slow first load of the
      # assets made five seconds too short once.
      expect(page).to have_current_path(/search=Alpha/, wait: 10)
      expect_titles('Alpha Kickoff')

      within('#meeting_new_form') do
        fill_in 'meeting[title]', with: 'Alpha Planung'
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Planung', wait: 5)
      expect_titles('Alpha Planung', 'Alpha Kickoff')
      expect(page).to have_current_path(/search=Alpha/)
    end

    it 'shows the errors of a refused save in the form, the chosen project kept' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      open_new_meeting

      select 'Projekt Beta', from: select_label
      within('#meeting_new_form') do
        fill_in 'meeting[title]', with: ''
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_new_form #meeting-form-card .bg-red-50', wait: 5)
      expect(page).to have_select(select_label, selected: 'Projekt Beta')
      expect(Meeting.unscoped.count).to eq(2)
    end

    it 'closes with Abbrechen: the lane shuts, new leaves the address, the list keeps its state' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, search: 'Alpha')
      expect_titles('Alpha Kickoff')

      open_new_meeting
      select 'Projekt Alpha', from: select_label
      within('#meeting_new_form') { click_link I18n.t('views.organisations.meetings.form.cancel') }

      expect(page).to have_no_css('#meeting-new-project', wait: 5)
      expect(page).to have_no_css('.labor-layout-view.show-content')
      expect(page).to have_no_current_path(/new=meeting/)
      expect(page).to have_current_path(/search=Alpha/)
      expect_titles('Alpha Kickoff')
    end

    # The list reload of the search remembers its list part with new=meeting in
    # it, and Escape reloads no list. Back pops new=meeting over that very list
    # part, which the restorer took for the closed lane (lib/lane/history).
    it 'opens the form again on Back after a search beside it and Escape' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      # A search value keeps the field open, as in the keyboard example below.
      visit organisation_meetings_path(organisation, search: 'a', search_mode: 'title_only')
      expect_titles('Alpha Kickoff', 'Beta Retro')

      open_new_meeting
      find('input[name="search"]').fill_in(with: 'Alpha')
      expect_titles('Alpha Kickoff')
      expect(page).to have_current_path(/search=Alpha/, wait: 5)
      expect(page).to have_current_path(/new=meeting/)
      expect(page).to have_css('#meeting_display_frame #meeting-new-project')

      find('#meeting_display_frame h2').click
      page.send_keys(:escape)
      expect(page).to have_no_css('#meeting-new-project', wait: 5)
      expect(page).to have_no_current_path(/new=meeting/, wait: 5)

      page.go_back
      expect(page).to have_current_path(/new=meeting/, wait: 5)
      expect(page).to have_css('#meeting_display_frame #meeting-new-project', wait: 5)
      expect(page).to have_css('.labor-layout-view.show-content')
      expect_titles('Alpha Kickoff')
    end

    # The refusal of the lane frame redirected back to this page with the frame
    # header kept, and the browser followed it until it gave up.
    it 'says so in the lane when the right to write went while the page stayed open' do
      writer = create(:user)
      permission = ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: 'Schreiber', organisation: organisation)
        create(:membership, user: writer, organisation: organisation, role: role, active: true)
        create(:project_permission, user: writer, project: alpha, meetings_access: 'read_write')
      end
      sign_in writer
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      expect_titles('Alpha Kickoff')

      ActsAsTenant.with_tenant(organisation) { permission.update!(meetings_access: 'read_only') }
      find(plus).click

      expect(page).to have_css('#meeting_display_frame', text: I18n.t('views.organisations.meetings_overview.new_meeting.denied'), wait: 5)
      expect(page).to have_no_css('#meeting-new-project')
      expect_titles('Alpha Kickoff')
    end

    it 'opens the select on a full visit with ?new=meeting' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, new: 'meeting', search: 'Alpha')

      expect(page).to have_css('#meeting_display_frame #meeting-new-project', wait: 5)
      expect(page).to have_css('.labor-layout-view.show-content')
      expect_titles('Alpha Kickoff')
    end

    it 'opens full width on a phone of 390 px, and Abbrechen and Speichern lead back to the list with its search' do
      page.driver.browser.manage.window.resize_to(390, 844)
      # In the phone layout from the start: without it the viewport controller
      # swaps the page for that layout a moment after the rows show.
      visit organisation_meetings_path(organisation, search: 'Alpha', viewport: 'mobile')
      expect(page).to have_css('#meetings_overview_results tr[data-meeting-id]', count: 1, wait: 10)

      open_new_meeting
      expect(page).to have_no_css('#meetings_overview_results tr[data-meeting-id]')
      expect(page).to have_current_path(/new=meeting/)
      select 'Projekt Alpha', from: select_label
      expect(page).to have_css('#meeting_new_form form', wait: 5)
      expect_no_sideways_scroll

      within('#meeting_new_form') { click_link I18n.t('views.organisations.meetings.form.cancel') }
      expect(page).to have_css('#meetings_overview_results tr[data-meeting-id]', count: 1, wait: 10)
      expect(page).to have_current_path(/search=Alpha/)
      expect(page).to have_no_current_path(/new=meeting/)

      open_new_meeting
      select 'Projekt Alpha', from: select_label
      within('#meeting_new_form') do
        fill_in 'meeting[title]', with: 'Alpha Handy'
        click_button I18n.t('views.organisations.meetings.form.save')
      end
      expect(page).to have_css('#meeting_display_frame h2', text: 'Alpha Handy', wait: 5)
      expect_no_sideways_scroll

      find('.mobile-ticket-view a', text: I18n.t('views.organisations.meetings.index.mobile_list_view'), match: :first).click
      expect(page).to have_css('#meetings_overview_results tr[data-meeting-id]', text: 'Alpha Handy', wait: 10)
      expect(page).to have_current_path(/search=Alpha/)
    end
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

    # The lane decides on connect: a check before that sees only the server's markup.
    def wait_for_layout_toggle
      wait_for_stimulus('.labor-layout-view', 'layout-toggle')
    end

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

    it 'keeps the list full width for a meeting_id it could not open, here and on the project page' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      gone = SecureRandom.uuid

      visit organisation_meetings_path(organisation, meeting_id: gone, search: 'Alpha')
      expect(page).to have_css(overview_rows, count: 2, wait: 10)
      wait_for_layout_toggle
      expect(page).to have_no_css('.labor-layout-view.show-content')
      expect(page).to have_no_css('#meeting_display_frame h2')
      expect(page).to have_no_current_path(/meeting_id=/, wait: 5)
      expect(page).to have_current_path(/search=Alpha/)

      # Another project's meeting is not this project's page's to open.
      visit organisation_project_meetings_path(organisation, alpha, meeting_id: meeting('Beta Retro').id)
      expect(page).to have_css('#meetings_results tr[data-meeting-id]', count: 2, wait: 10)
      wait_for_layout_toggle
      expect(page).to have_no_css('.labor-layout-view.show-content')
      expect(page).to have_no_current_path(/meeting_id=/, wait: 5)
    end

    it 'keeps the overview context through a link rendered without it' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation)
      expect_titles('Alpha Kickoff', 'Beta Retro', 'Alpha Ohne Anna')
      row_of('Beta Retro').click
      expect(lane_title).to have_text('Beta Retro')

      # What a section refresh or a broadcast renders: the detail address
      # without list_context, since neither knows which list is open.
      beta = meeting('Beta Retro')
      href = organisation_project_meeting_path(organisation, beta.project_id, beta, frame: 'content')
      page.execute_script(<<~JS, href)
        const link = document.createElement('a')
        link.id = 'contextless-refresh'
        link.href = arguments[0]
        link.dataset.turboFrame = 'meeting_display_frame'
        link.textContent = 'aktualisieren'
        document.getElementById('meeting_display_frame').append(link)
      JS
      find('#contextless-refresh').click
      expect(page).to have_no_css('#contextless-refresh', wait: 5)
      expect(lane_title).to have_text('Beta Retro')

      edit = "a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']"
      within('#meeting_display_frame') { find(edit, match: :first).click }
      within('#meeting_display_frame') do
        fill_in 'meeting[title]', with: 'Beta Retro neu'
        click_button I18n.t('views.organisations.meetings.form.save')
      end

      expect(page).to have_css('#meeting_display_frame h2', text: 'Beta Retro neu', wait: 5)
      expect_titles('Alpha Kickoff', 'Beta Retro neu', 'Alpha Ohne Anna')
    end

    it 'keeps the open meeting when the list is saved as a view' do
      page.driver.browser.manage.window.resize_to(1440, 1000)
      visit organisation_meetings_path(organisation, filter: { participant: ['Anna'] })
      expect_titles('Alpha Kickoff', 'Beta Retro')
      row_of('Beta Retro').click
      expect(lane_title).to have_text('Beta Retro')

      click_button 'Als Ansicht sichern'
      fill_in 'smart_folder_name', with: 'Mit Anna'
      click_button 'Sichern'

      expect(page).to have_css('[role="tab"][aria-selected="true"]', text: 'Mit Anna', wait: 5)
      expect(lane_title).to have_text('Beta Retro')
      expect(page).to have_current_path(/meeting_id=#{meeting('Beta Retro').id}/)
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
