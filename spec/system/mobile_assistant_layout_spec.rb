# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Mobile assistant layout', type: :system do
  let(:organisation) { create(:organisation, assistant_enabled: true) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role)
    create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: true)
    sign_in user
  end

  after do
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def viewport(width)
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: width < 1024)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: width, height: 844,
                                                                          deviceScaleFactor: 1, mobile: width < 1024)
  end

  def expect_phone_lane(selector)
    expect(page).to have_css(selector)
    expect(page).to have_css('html') { |root| root.evaluate_script('document.documentElement.scrollWidth === document.documentElement.clientWidth') }
    expect(find(selector).native.rect.width).to be >= page.evaluate_script('window.innerWidth - 40')
    expect(page).to have_no_css('#assistant_panel_history', visible: true)
    expect(page).to have_no_css('[data-assistant-panel-target="expandButton"]', visible: true)
    expect(page).to have_no_css('[data-assistant-panel-target="collapseButton"]', visible: true)
    expect(page).to have_css('[data-assistant-panel-target="historyButton"]', visible: true)
  end

  it 'keeps an expanded desktop chat readable after resizing and restoring on a phone' do
    viewport(1280)
    visit organisation_root_path(organisation)
    find('#assistant-panel-trigger').click
    find('[data-assistant-panel-target="expandButton"]').click
    expect(page).to have_css('.assistant-panel--full #assistant_panel_history')

    [320, 390].each do |width|
      viewport(width)
      expect_phone_lane('#assistant_panel_body')
    end

    page.refresh
    expect_phone_lane('#assistant_panel_body')
    find('[data-assistant-panel-target="historyButton"]').click
    expect(page).to have_css('#assistant_panel_body [data-assistant-history]')

    viewport(1280)
    expect(page).to have_css('.assistant-panel--full #assistant_panel_history')
    expect(page).to have_css('[data-assistant-panel-target="collapseButton"]')
  end

  it 'shows a restored report at full phone width and returns to chat or history' do
    viewport(320)
    path = organisation_root_path(organisation, assistant: 'full',
                                                assistant_artefact: { kind: 'report', project_id: project.id }.to_query)
    visit path
    expect(page).to have_css('#assistant_panel_artefact [data-action="assistant-panel#closeArtefact"]')
    expect_phone_lane('#assistant_panel_artefact')
    expect(page).to have_no_css('#assistant_panel_body', visible: true)

    find('[data-action="assistant-panel#closeArtefact"]').click
    expect_phone_lane('#assistant_panel_body')
    expect(page).to have_no_css('#assistant_panel_artefact', visible: true)

    visit path
    expect_phone_lane('#assistant_panel_artefact')
    find('[data-assistant-panel-target="historyButton"]').click
    expect(page).to have_css('#assistant_panel_body [data-assistant-history]')
    expect(page).to have_no_css('#assistant_panel_artefact', visible: true)
  end
  it 'closes the phone sheet when a source opens a real page' do
    viewport(390)
    visit organisation_root_path(organisation, assistant: 'panel')
    find('.mobile-header [data-controller="assistant-trigger"]').click unless page.has_css?('#assistant_panel_body', wait: 1)
    expect_phone_lane('#assistant_panel_body')
    destination = organisation_mobile_more_path(organisation)
    page.execute_script(<<~JS, destination)
      const link = document.createElement('a')
      link.href = arguments[0]
      link.dataset.turboFrame = '_top'
      link.textContent = 'Quelle öffnen'
      document.querySelector('#assistant_panel_body').prepend(link)
    JS
    page.execute_script("document.addEventListener('turbo:before-visit', event => event.preventDefault(), { once: true })")
    click_link 'Quelle öffnen'
    expect_phone_lane('#assistant_panel_body')
    expect(page).not_to have_current_path(destination)
    click_link 'Quelle öffnen'
    expect(page).to have_current_path(destination)
    expect(page).to have_no_css('.mobile-app-screen[inert]')
    expect(page).to have_no_css('#assistant_panel_body', visible: true)
    expect(page).to have_link(I18n.t('navigation.preferences'), visible: true)
  end
  it 'keeps the sheet open when cancelling or confirming a message deletion' do
    chat = create(:chat, :org_thread, organisation: organisation, user: user)
    chat.chatposts.first.update!(user: user, content: 'Erste Frage')
    message = create(:chatpost, chat: chat, organisation: organisation, user: user,
                                role: 'assistant', content: 'Diese Antwort kann gelöscht werden.')
    viewport(390)
    visit organisation_root_path(organisation, assistant: 'panel', assistant_chat_id: chat.id)
    selector = "#chatpost_#{message.id} a[data-turbo-method=delete]"
    expect(page).to have_css(selector)
    dismiss_confirm { find(selector).click }
    expect_phone_lane('#assistant_panel_body')
    expect(page).to have_css("#chatpost_#{message.id}")
    expect(message.reload).to be_present

    accept_confirm { find(selector).click }
    expect(page).to have_no_css("#chatpost_#{message.id}")
    expect_phone_lane('#assistant_panel_body')
    expect(Chatpost.exists?(message.id)).to be(false)
  end
end
