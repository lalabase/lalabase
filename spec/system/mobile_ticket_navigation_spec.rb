# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Mobile ticket navigation', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Produktselektor') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    create(:ticket, project: project, title: 'Anpassen des Scorings für Multiple Penetrations')
    create(:ticket, project: project, title: 'Produktpflege im Admin-Backend auf eine einheitliche Technik bringen')
    sign_in user
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    expect(page).to have_css('.mobile-ticket-title', count: 2)
  end

  after do
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  it 'fits the list above the navigation and opens the project sheet' do
    expect(page).to have_no_css('#sidebar', visible: true)
    overflow = page.evaluate_script('document.documentElement.scrollWidth > window.innerWidth')
    expect(overflow).to be(false)
    find('.mobile-heading button').click
    expect(page).to have_css('dialog[open] #mobile-project-title')
    expect(page).to have_css('dialog[open] .mobile-project-name', text: project.name)
    find('button[aria-label="Schließen"]', match: :first).click
    expect(page).to have_no_css('dialog[open]')
    File.binwrite(Rails.root.join('tmp/lalabase-mobile-list.png'), page.driver.browser.screenshot_as(:png))
    page.execute_script("window.__lbTheme.set('light')")
    File.binwrite(Rails.root.join('tmp/lalabase-mobile-list-light.png'), page.driver.browser.screenshot_as(:png))
    page.execute_script("window.__lbTheme.set('pop')")
  end

  it 'searches in place and preserves the mobile list' do
    find('.mobile-header button[aria-label="Suchen"]').click
    find('.mobile-ticket-list input[type="search"]').fill_in(with: 'Produktpflege')
    expect(page).to have_css('.mobile-ticket-title', count: 1)
    expect(page).to have_no_css('#tickets_list_frame table')
    expect(page).to have_css('.mobile-bottom-links')
  end

  it 'restores search results and controls with browser Back and Forward' do
    find('.mobile-header button[aria-label="Suchen"]').click
    find('.mobile-ticket-list input[type="search"]').fill_in(with: 'Produktpflege')
    expect(page).to have_css('.mobile-ticket-title', count: 1)
    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Produktpflege')
    first_address = page.current_url
    expect(Rack::Utils.parse_nested_query(URI.parse(first_address).query)['search']).to eq('Produktpflege')
    find('.mobile-ticket-list input[type="search"]').fill_in(with: 'Anpassen')
    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Anpassen')
    second_address = page.current_url
    expect(Rack::Utils.parse_nested_query(URI.parse(second_address).query)['search']).to eq('Anpassen')

    # Traverse one pushed entry and exercise the native popstate handler.
    page.execute_script('window.history.back()')
    expect(page).to have_current_path(first_address, url: true)
    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Produktpflege')
    expect(page).to have_field(type: 'search', with: 'Produktpflege')
    page.execute_script('window.history.forward()')
    expect(page).to have_current_path(second_address, url: true)
    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Anpassen')
    expect(page).to have_field(type: 'search', with: 'Anpassen')
  end

  it 'returns from a ticket to the same filtered and sorted second page' do
    tag = create(:tag, name: 'mobile-return', organisation: organisation)
    %w[A B].each do |suffix|
      ticket = create(:ticket, project: project, title: "Navigation #{suffix}")
      create(:tagging, tag: tag, taggable: ticket)
    end
    create(:ticket, project: project, title: 'Navigation C')
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile', items: 1,
                                                                   search: 'Navigation', search_mode: 'title_only',
                                                                   filter: { tag: [tag.name] }, sort: { column: 'title', direction: 'desc' })
    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Navigation B')
    within('.mobile-pagination') { click_link I18n.t('mobile.next') }
    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Navigation A')
    click_link 'Navigation A'
    expect(page).to have_css('.mobile-ticket-detail')
    click_link I18n.t('mobile.back_tickets')

    expect(page).to have_css('.mobile-ticket-title', count: 1, text: 'Navigation A')
    expect(page).to have_css('.mobile-pagination', text: '2 / 2')
    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    expect(query).to include('page' => '2', 'filter' => { 'tag' => [tag.name] },
                             'sort' => { 'column' => 'title', 'direction' => 'desc' }, 'search' => 'Navigation')
  end

  it 'selects tickets and opens the bulk editor only on request' do
    find('button[aria-label="Tickets auswählen"]').click
    expect(page).to have_css('.mobile-ticket-check input', count: 2)
    expect(page).to have_no_css('dialog[open]')
    find('.mobile-ticket-check input', match: :first).click
    expect(page).to have_css('.mobile-selection-head', text: '1 ausgewählt')
    find('.mobile-bottom-actions button', text: '1 bearbeiten').click
    expect(page).to have_css('dialog[open] .ticket-bulk-panel')
    find('button', text: 'Zur Ticketliste').click
    find('button[aria-label="Auswahl beenden"]').click
    expect(page).to have_css('.mobile-bottom-links')
    expect(page).to have_no_css('.mobile-ticket-check input', visible: true)
  end

  it 'opens a ticket and returns to the list with navigation intact' do
    find('.mobile-ticket-title', text: 'Anpassen des Scorings für Multiple Penetrations').click
    expect(page).to have_css('.mobile-ticket-detail')
    expect(page).to have_no_css('.mobile-ticket-detail [data-action="click->layout-toggle#closeContent"]', visible: true)
    expect(page).to have_css('.mobile-bottom-links .is-active', text: 'Projekte')
    click_link 'Zur Ticketliste'
    expect(page).to have_css('.mobile-ticket-title', count: 2)
  end

  it 'keeps mobile rows after bulk saving from project navigation without a viewport query' do
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: { 'allowed_values' => [{ 'value' => 'mobile_done', 'labels' => { 'de' => 'Mobil erledigt', 'en' => 'Mobile done' } }] })
    visit organisation_mobile_projects_path(organisation)
    within('.mobile-destination .mobile-project-list') { click_link project.name }
    expect(page).to have_css('.mobile-ticket-title', count: 2)
    expect(URI.parse(page.current_url).query.to_s).not_to include('viewport')

    find('button[aria-label="Tickets auswählen"]').click
    find('.mobile-ticket-check input', match: :first).click
    find('.mobile-bottom-actions button', text: '1 bearbeiten').click
    within('dialog[open] .ticket-bulk-panel') do
      find('[data-ticket-bulk-panel-target="pickerButton"]').click
      find('[data-picker-option][data-field="status"]').click
      find('.ticket-bulk-row[data-field="status"] .tbp-select').click
      find('.ticket-bulk-row[data-field="status"] [data-value="mobile_done"]').click
      find('[data-ticket-bulk-panel-target="execute"]:not([disabled])')
      page.document.synchronize do
        ready = page.evaluate_script("Boolean(window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('.ticket-bulk-panel'), 'ticket-bulk-panel').summary?.fields?.status)")
        raise Capybara::ExpectationNotMet, 'summary is loading' unless ready
      end
      # Reproduce a stale summary so the server refuses the first write.
      page.execute_script(<<~JS)
        const element = document.querySelector('.ticket-bulk-panel')
        window.Stimulus.getControllerForElementAndIdentifier(element, 'ticket-bulk-panel').summary.fields.status.digest = 'obsolete'
      JS
      find('[data-ticket-bulk-panel-target="execute"]:not([disabled])').click
      expect(page.document).to have_css('dialog[open] #ticket-selection-result [role="alert"]', text: I18n.t('views.organisations.tickets.bulk.errors.stock_changed'))
      expect(page).to have_css('.ticket-bulk-row[data-field="status"]')
      page.document.synchronize do
        digest = page.evaluate_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('.ticket-bulk-panel'), 'ticket-bulk-panel').summary.fields.status.digest")
        raise Capybara::ExpectationNotMet, 'summary has not refreshed' if digest == 'obsolete'
      end
      find('[data-ticket-bulk-panel-target="execute"]:not([disabled])').click
    end
    expect(page).to have_css('dialog[open] #ticket-selection-result [data-run-ticket-ids]')
    expect(page).to have_button(I18n.t('views.organisations.tickets.bulk.result.undo'))
    find('button', text: 'Zur Ticketliste').click
    find('button[aria-label="Auswahl beenden"]').click
    expect(page).to have_button(I18n.t('views.organisations.tickets.bulk.result.undo'))
    expect(page).to have_css('.mobile-ticket-status', text: 'Mobil erledigt')
    expect(page).to have_css('.mobile-ticket-title', count: 2)
    expect(page).to have_no_css('#tickets_list_frame table')
  end

  it 'creates a ticket through the mobile primary action' do
    find('.mobile-header a[aria-label="Neues Ticket"]').click
    within '#writing_surface' do
      fill_in 'ticket[title]', with: 'Unterwegs angelegt'
      find('button[type="submit"]').click
    end
    expect(page).to have_css('.mobile-ticket-title', text: 'Unterwegs angelegt')
    expect(page).to have_no_css('#writing_surface form')
    expect(page).to have_no_css('#tickets_list_frame table')
  end

  it 'recognizes a long touch and cancels selection when a touch moves' do
    row = find('.mobile-ticket-row', match: :first)
    page.execute_script(<<~JS, row)
      arguments[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerType: 'touch', isPrimary: true, clientX: 100, clientY: 300 }));
      arguments[0].dispatchEvent(new PointerEvent('pointermove', { bubbles: true, pointerType: 'touch', isPrimary: true, clientX: 100, clientY: 340 }));
    JS
    sleep 0.5
    expect(page).to have_no_css('.mobile-selecting')
    page.execute_script("arguments[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerType: 'touch', isPrimary: true, clientX: 100, clientY: 300 }))", row)
    expect(page).to have_css('.mobile-selection-head', text: '1 ausgewählt')
    page.execute_script("arguments[0].dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerType: 'touch', isPrimary: true }))", row)
    expect(page).to have_no_css('dialog[open]')
    File.binwrite(Rails.root.join('tmp/lalabase-mobile-selection.png'), page.driver.browser.screenshot_as(:png))
  end

  it 'fits the narrowest phone and keeps the last row above the bottom bar' do
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 320, height: 667, deviceScaleFactor: 1, mobile: true)
    expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be(true)
    bottom = page.evaluate_script("document.querySelector('.mobile-bottom-bar').getBoundingClientRect().top")
    content_bottom = page.evaluate_script("document.querySelector('.mobile-app-screen > main').getBoundingClientRect().bottom")
    expect(content_bottom).to be <= bottom
    expect(find('.mobile-header a[aria-label="Neues Ticket"]').native.rect.width).to be >= 44
  end
  it 'opens the assistant above the page and restores the page on close' do
    organisation.update!(assistant_enabled: true)
    role = user.memberships.find_by!(organisation: organisation).role
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    find('.mobile-header [aria-label="Assistent"]').click
    expect(page).to have_css('#assistant_panel [role="dialog"][aria-modal="true"]')
    expect(page.evaluate_script("document.querySelector('.mobile-app-screen').inert")).to be(true)
    find('#assistant_panel [data-assistant-panel-target="panel"] button[data-action="assistant-panel#close"]').click
    expect(page.evaluate_script("document.querySelector('.mobile-app-screen').inert")).to be(false)
    expect(page).to have_css('.mobile-bottom-links')
  end

  it 'switches projects from a filtered list and keeps the ticket area' do
    other_project = create(:project, organisation: organisation, name: 'WebApp2')
    create(:ticket, project: other_project, title: 'Ticket im zweiten Projekt')
    visit organisation_project_tickets_path(organisation, project, viewport: 'mobile')
    find('.mobile-header button[aria-label="Suchen"]').click
    find('.mobile-ticket-list input[type="search"]').fill_in(with: 'Produktpflege')
    expect(page).to have_css('.mobile-ticket-title', count: 1)
    find('.mobile-heading button').click
    # The persistent header was rendered before the search changed the URL.
    within('dialog[open]') { click_link 'WebApp2' }
    expect(page).to have_css('.mobile-heading', text: 'WebApp2')
    expect(page).to have_css('.mobile-ticket-title', text: 'Ticket im zweiten Projekt')
    expect(page).to have_css('[role="status"]', text: 'Filter')
    expect(page).to have_css('.mobile-project-tabs [aria-current]', text: 'Tickets')
  end

  it 'uses one boundary for the ticket list and the application navigation' do
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 768, height: 1024, deviceScaleFactor: 1, mobile: true)
    expect(page).to have_css('.mobile-ticket-title', count: 2)
    expect(page).to have_css('.mobile-bottom-links')
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 1024, height: 768, deviceScaleFactor: 1, mobile: false)
    expect(page).to have_css('#tickets_list_frame table')
    expect(page).to have_no_css('.mobile-bottom-links', visible: true)
  end
  it 'cancels a long touch when the row disappears before the gesture completes' do
    row = find('.mobile-ticket-row', match: :first)
    page.execute_script(<<~JS, row)
      arguments[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerType: 'touch', isPrimary: true, clientX: 100, clientY: 300 }))
      arguments[0].remove()
    JS
    sleep 0.5
    expect(page).to have_no_css('.mobile-selecting')
  end
  it 'keeps selection when pagination adds the viewport to the project-tab address' do
    create_list(:ticket, 19, project: project)
    visit organisation_mobile_projects_path(organisation)
    within('.mobile-destination .mobile-project-list') { click_link project.name }
    expect(page).to have_css('.mobile-ticket-title', count: 20)
    expect(URI.parse(page.current_url).query.to_s).not_to include('viewport')
    find('button[aria-label="Tickets auswählen"]').click
    find('.mobile-ticket-check input', match: :first).click
    within('.mobile-pagination') { click_link I18n.t('mobile.next') }
    expect(page).to have_css('.mobile-pagination', text: '2 / 2')
    expect(page).to have_css('.mobile-selection-head', text: '1 ausgewählt')
    expect(page).to have_css('.mobile-ticket-check input:not(:checked)')
    find('.mobile-ticket-check input').click
    expect(page).to have_css('.mobile-selection-head', text: '2 ausgewählt')
  end
end
