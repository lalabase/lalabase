# frozen_string_literal: true

require 'rails_helper'

# Real Turbo navigation and CSS: the global assistant and meeting detail entries
# must work on the same page, including detail-frame changes.
RSpec.describe 'Meetings in the assistant', type: :system do
  before { driven_by :selenium_chrome_headless_full }
  before { Prosopite.pause }
  after { Prosopite.resume }

  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:first) { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Planungsrunde', notes: 'Start im Mai') }
  let(:second) { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Budgetrunde', transcript: 'Budget offen') }
  let(:offer) { '[data-assistant-panel-target="offer"]' }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    first
    second
    sign_in user
  end

  it 'takes a draft, follows a meeting switch, saves the first message and removes one reference' do
    visit organisation_project_meetings_path(organisation, project, meeting_id: first.id)
    find('#assistant-panel-trigger').click
    expect(page).to have_css(offer, text: 'Planungsrunde')
    find('[data-assistant-panel-target="offerTake"]').click
    expect(page).to have_css('[data-draft-reference]', text: 'Planungsrunde')
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)

    find('#meeting-header [data-action="click->layout-toggle#closeContent"]').click
    expect(page).to have_no_css(offer)
    find("[data-meetings-row-item-id-value='#{second.id}']").click
    expect(page).to have_css(offer, text: 'Budgetrunde')
    expect(page).to have_css('[data-draft-reference]', text: 'Planungsrunde')
    find('#meeting-header [data-controller="assistant-trigger"]').click
    expect(page).to have_css('[data-draft-reference]', count: 2)

    find('[data-draft-reference]', text: 'Planungsrunde').find('button').click
    expect(page).to have_css('[data-draft-reference]', count: 1)
    find('#assistant_panel textarea').set('Fasse dieses Meeting zusammen.')
    find('#assistant_panel textarea').send_keys(:enter)
    expect(page).to have_css('#assistant-panel-chat')
    expect(ActsAsTenant.with_tenant(organisation) { Chat.last.scope_references })
      .to eq([{ 'type' => 'Meeting', 'id' => second.id }])

    expect(page).to have_no_css('#meeting_analyses_lane')
    expect(page).to have_button('Analyse erstellen')
    expect(page).to have_button('Aufgaben ableiten')
    expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be true

    find('#assistant_panel [data-reference-keys] button[type="submit"]').click
    expect(page).to have_no_css('#assistant_panel [data-reference-keys] button[type="submit"]')
    expect(ActsAsTenant.with_tenant(organisation) { Chat.last.scope_references }).to eq([])
    expect(page).to have_css(offer, text: 'Budgetrunde')
  end

  it 'takes the meeting into the mobile assistant and retains inline analyses after closing it' do
    original_size = page.driver.browser.manage.window.size
    page.driver.browser.manage.window.resize_to(390, 844)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
    visit organisation_project_meetings_path(organisation, project, meeting_id: first.id, viewport: 'mobile')

    expect(page).to have_css('#meeting-header', text: 'Planungsrunde')
    find('#meeting-header [data-controller="assistant-trigger"]').click
    expect(page).to have_css('#assistant_panel_body [data-draft-reference]', text: 'Planungsrunde')
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)
    find('#assistant_panel [data-assistant-panel-target="panel"] [data-action="assistant-panel#close"]').click
    expect(page).to have_no_css('#assistant_panel_body', visible: true)
    expect(page).to have_no_css("form[action='#{organisation_project_meeting_analyses_path(organisation, project, first)}']")
    expect(page).to have_button('Analyse erstellen')
    expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be true
  ensure
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.driver.browser.manage.window.resize_to(original_size.width, original_size.height) if original_size
  end

  it 'keeps the assistant draft through meeting history, filtered navigation and a new-meeting form' do
    page.driver.browser.manage.window.resize_to(1920, 1080)
    visit organisation_project_meetings_path(organisation, project, meeting_id: first.id)
    within "#analyses_meeting_#{first.id}" do
      click_button 'Analyse erstellen'
    end
    find('#assistant_panel textarea').set('Diesen Entwurf behalten.')
    find('#meeting-header [data-lane-close]').click
    find("[data-meetings-row-item-id-value='#{second.id}']").click
    expect(page).to have_css('#meeting-header', text: 'Budgetrunde')
    page.go_back
    expect(page).to have_no_css('#meeting-header')
    page.go_back
    expect(page).to have_css('#meeting-header', text: 'Planungsrunde')
    page.go_forward
    expect(page).to have_no_css('#meeting-header')
    page.go_forward
    expect(page).to have_css('#meeting-header', text: 'Budgetrunde')
    expect(find('#assistant_panel textarea').value).to eq('Diesen Entwurf behalten.')

    page.execute_script('Turbo.visit(arguments[0])', organisation_project_meetings_path(organisation, project, search: 'Planungs', new: 'meeting'))
    expect(page).to have_css('#meeting_display_frame input[name="meeting[title]"]')
    expect(find('input[type="search"][name="search"]', visible: :all).value).to eq('Planungs')
    expect(find('#assistant_panel textarea').value).to eq('Diesen Entwurf behalten.')
    find('#meeting_display_frame [data-lane-close]').click
    expect(page).to have_no_css('#meeting_display_frame input[name="meeting[title]"]')
    expect(find('input[type="search"][name="search"]').value).to eq('Planungs')
    expect(URI.parse(page.current_url).query).not_to include('new=')
    page.go_back
    expect(page).to have_css('#meeting_display_frame input[name="meeting[title]"]')
    expect(find('#assistant_panel textarea').value).to eq('Diesen Entwurf behalten.')
  end
end
