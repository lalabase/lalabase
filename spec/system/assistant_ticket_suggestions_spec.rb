# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meeting ticket suggestions in the assistant', type: :system do
  include_context 'assistant ticket suggestions'

  before do
    driven_by :selenium_chrome_headless_full
    Prosopite.pause
    meeting
    sign_in user
  end
  after { Prosopite.resume }

  [false, true].each do |existing_chat|
    it "keeps task controls reachable in a short mobile viewport (existing chat: #{existing_chat})" do
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 460,
                                                                            deviceScaleFactor: 1, mobile: true)
      visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id,
                                                                      assistant_chat_id: existing_chat ? chat.id : nil,
                                                                      viewport: 'mobile')
      if existing_chat
        within '#assistant_panel' do
          click_button 'Assistent schließen'
        end
      end
      within "#analyses_meeting_#{meeting.id}" do
        click_button 'Analyse erstellen'
      end
      within '#assistant_panel' do
        click_button 'Aufgaben ableiten'
        field = find('textarea')
        field.click
        expect(page).to have_css('textarea:focus')
        field.send_keys(:tab)
        send_button = find('button[aria-label="Senden"]')
        expect(page).to have_css('button[aria-label="Senden"]:focus')
        expect(send_button.evaluate_script('this.getBoundingClientRect().bottom')).to be <= 460
        page.save_screenshot(Rails.root.join("tmp/screenshots/assistant-tasks-short-#{existing_chat}.png")) # rubocop:disable Lint/Debugger -- mobile QA evidence
        send_button.send_keys(:enter)
        expect(page).to have_text('Aufgaben aus Planungsrunde werden abgeleitet')
        click_button 'Assistent schließen'
      end
      expect(page).to have_no_css('#assistant_panel_body', visible: true)
    ensure
      page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    end
  end

  [1280, 390].each do |width|
    it "prepares, restores, generates, accepts and dismisses at #{width}px" do
      page.driver.browser.manage.window.resize_to(1280, 900)
      page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: width < 600)
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: width, height: 900, deviceScaleFactor: 1, mobile: width < 600)
      visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id, viewport: width < 1024 ? 'mobile' : nil)
      within "#ticket_suggestions_meeting_#{meeting.id}" do
        click_button 'Aufgaben ableiten'
      end
      within '#assistant_panel' do
        expect(page).to have_css('textarea', count: 1)
        expect(page).to have_text('Vorschläge sind für Personen mit Zugriff auf dieses Meeting sichtbar.')
        expect(find('select[aria-label="Meeting und Zielprojekt"]').value).to eq(meeting.id)
        click_button 'Aufgabenmodus beenden'
        find('textarea').set('Mein Entwurf.')
        page.execute_script("document.querySelector('#ticket_suggestions_meeting_#{meeting.id} button').click()")
        expect(find('textarea').value).to start_with("Mein Entwurf.\n\n")
        expect(find('textarea').value).to include('Mein Entwurf.')
        expect(find('select[aria-label="Meeting und Zielprojekt"]').value).to eq(meeting.id)
        draft = find('textarea').value
        page.execute_script("document.querySelector('#analyses_meeting_#{meeting.id} button').click()")
        expect(page).to have_no_select('Meeting und Zielprojekt')
        expect(page).to have_css('[data-meeting-analysis-composer-target="tools"][open]')
        expect(find('textarea').value).to eq(draft)
        page.execute_script("document.querySelector('#ticket_suggestions_meeting_#{meeting.id} button').click()")
        expect(find('select[aria-label="Meeting und Zielprojekt"]').value).to eq(meeting.id)
        find('textarea').set('Nur Aufgaben mit einem klaren nächsten Schritt.')
        find('textarea').send_keys(:enter)
      end
      expect(page).to have_text('Aufgaben aus Planungsrunde werden abgeleitet')
      run = in_org { MeetingTicketSuggestionRun.last }
      expect(in_org { Ticket.count }).to eq(0)
      expect(ChatResponseJob).not_to have_received(:perform_later)
      second = in_org { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Anderes Meeting', notes: 'Anderes Thema') }
      visit organisation_project_meetings_path(organisation, project, meeting_id: second.id, assistant_chat_id: run.chatpost.chat_id, viewport: width < 1024 ? 'mobile' : nil)
      expect(page).to have_css('#assistant-panel-chat')
      within '#assistant_panel' do
        expect(page).to have_text('Aufgaben aus Planungsrunde werden abgeleitet')
        expect(page).to have_css('textarea', count: 1)
      end
      in_org { finish_run(run) }
      within '#assistant_panel' do
        expect(page).to have_text('Rechnung senden', wait: 35)
        expect(page).to have_text('Angebot prüfen')
        expect(page).to have_no_text('werden abgeleitet')
        expect(page).to have_button('Als Ticket anlegen', count: 2)
        page.save_screenshot(Rails.root.join("tmp/screenshots/assistant-tasks-#{width}.png")) # rubocop:disable Lint/Debugger -- desktop/mobile QA evidence
        within '[data-suggestion-id]', match: :first do
          click_button 'Als Ticket anlegen'
          expect(page).to have_text('Ticket #')
          expect(page).to have_link('Ticket öffnen')
          expect(page).to have_no_button('Als Ticket anlegen')
        end
        click_button 'Verwerfen'
        expect(page).to have_text('Verworfen')
      end
      expect(in_org { Ticket.count }).to eq(1)
      expect(in_org { meeting.outgoing_references.where(target: Ticket.last).exists? }).to be true
      page.refresh
      within '#assistant_panel' do
        expect(page).to have_text('Ticket #')
        expect(page).to have_text('Verworfen')
        expect(page).to have_no_button('Als Ticket anlegen')
        page.save_screenshot(Rails.root.join("tmp/screenshots/assistant-tasks-finished-#{width}.png")) # rubocop:disable Lint/Debugger -- retained QA evidence
      end
      expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be true
    ensure
      page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
      page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    end
  end

  it 'requires a target with two references and restores explicit mode across navigation' do
    second = in_org { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Budgetrunde', notes: 'Budget klären') }
    thread = in_org do
      chat.update!(scope_references: [meeting, second].map { |record| { type: 'Meeting', id: record.id } })
      chat
    end
    visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id, assistant_chat_id: thread.id)
    within '#assistant_panel' do
      click_button 'Aufgaben ableiten'
      expect(find('select[aria-label="Meeting und Zielprojekt"]').value).to eq('')
      find('textarea').send_keys(:enter)
      expect(in_org { MeetingTicketSuggestionRun.count }).to eq(0)
      # Native selects emit input before change; Selenium's select helper skips input.
      page.execute_script(<<~JS, second.id)
        const select = document.querySelector('#assistant_panel select[aria-label="Meeting und Zielprojekt"]')
        select.value = arguments[0]
        select.dispatchEvent(new Event('input', { bubbles: true }))
        select.dispatchEvent(new Event('change', { bubbles: true }))
      JS
      expect(find('select[aria-label="Meeting und Zielprojekt"]').value).to eq(second.id)
      find('textarea').set('Nur Budgetaufgaben.')
      page.execute_script('Turbo.visit(arguments[0])', organisation_project_meetings_path(organisation, project, meeting_id: second.id))
    end
    expect(page).to have_css('#meeting-header', text: 'Budgetrunde')
    within '#assistant_panel' do
      expect(page).to have_css('textarea') { |field| field.value == 'Nur Budgetaufgaben.' }
      expect(find('select[aria-label="Meeting und Zielprojekt"]').value).to eq(second.id)
      find('textarea').send_keys(:enter)
      expect(page).to have_text('Aufgaben aus Budgetrunde werden abgeleitet')
    end
    run = in_org { MeetingTicketSuggestionRun.last }
    in_org do
      allow(provider).to receive(:chat).and_raise(StandardError, 'network')
      finish_run(run)
    end
    within '#assistant_panel' do
      expect(page).to have_button('Erneut versuchen', wait: 35)
      click_button 'Erneut versuchen'
      expect(page).to have_text('Aufgaben aus Budgetrunde werden abgeleitet')
    end
    retried = in_org { MeetingTicketSuggestionRun.order(:created_at).last }
    in_org do
      allow(provider).to receive(:chat).and_return(content: '[]', token_usage: {}, model_used: 'test')
      finish_run(retried)
    end
    within '#assistant_panel' do
      expect(page).to have_text('In diesem Meeting wurden keine konkreten Aufgaben gefunden.', wait: 35)
    end
  end

  it 'keeps the assistant, meeting list and linked tickets synchronized without a reload' do
    run = in_org do
      created = start_run
      finish_run(created)
    end
    visit organisation_project_meetings_path(
      organisation, project, meeting_id: meeting.id, assistant_chat_id: run.chatpost.chat_id
    )

    within '#assistant_panel' do
      expect(page).to have_text('Rechnung senden')
      within find('[data-suggestion-id]', text: 'Rechnung senden') do
        click_button 'Als Ticket anlegen'
        expect(page).to have_text('Ticket #')
      end
    end
    within "#ticket_suggestions_meeting_#{meeting.id}" do
      expect(page).to have_no_text('Rechnung senden')
      expect(page).to have_text('Angebot prüfen')
    end
    within "#ticket_links_meeting_#{meeting.id}" do
      expect(page).to have_text('Rechnung senden')
    end

    within "#ticket_suggestions_meeting_#{meeting.id}" do
      within find('[data-suggestion-id]', text: 'Angebot prüfen') do
        click_button 'Verwerfen'
      end
    end
    within '#assistant_panel' do
      within find('[data-suggestion-id]', text: 'Angebot prüfen') do
        expect(page).to have_text('Verworfen')
      end
    end
  end
end
