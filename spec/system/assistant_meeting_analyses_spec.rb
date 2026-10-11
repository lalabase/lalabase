# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meeting analyses in the assistant', type: :system do
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
  let(:second) { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Budgetrunde', notes: 'Budget offen') }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: project, meetings_access: 'read_write')
    first
    second
    create(:analysis_prompt, organisation: organisation, creator: user, title: 'Entscheidungsprotokoll', prompt_text: 'Fasse verbindliche Entscheidungen zusammen.')
    sign_in user
  end

  def in_org(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  [1280, 390].each do |width|
    it "uses one composer, preserves the draft and saves the selected answer at #{width}px" do
      page.driver.browser.manage.window.resize_to(1280, 900)
      page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: width < 600)
      page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: width, height: 900, deviceScaleFactor: 1, mobile: width < 600)
      visit organisation_project_meetings_path(organisation, project, meeting_id: first.id, viewport: width < 1024 ? 'mobile' : nil)
      within "#analyses_meeting_#{first.id}" do
        click_button 'Analyse erstellen'
      end
      expect(page).to have_css('[data-draft-reference]', text: 'Planungsrunde')
      within '#assistant_panel' do
        expect(page).to have_css('textarea', count: 1)
        expect(page).to have_text('Meeting analysieren')
        field = find('textarea')
        field.set('Mein eigener Entwurf.')
        click_button 'Entscheidungen zusammenfassen'
        expect(field.value).to start_with("Mein eigener Entwurf.\n\n")
        expect(page).to have_text('Auftrag an deinen Entwurf angehängt')
        click_button 'Vorlage wählen'
        fill_in 'Vorlagen durchsuchen', with: 'Entscheidungsprotokoll'
        click_button 'Entscheidungsprotokoll'
        expect(field.value).to include('Mein eigener Entwurf.', 'Fasse verbindliche Entscheidungen zusammen.')
        expect(in_org { Chat.count }).to eq(0)
        field.set('Nur verbindliche Entscheidungen mit Verantwortlichen.')
        click_button 'Als Vorlage speichern', match: :first
        fill_in 'Vorlagentitel', with: 'Mit Verantwortlichen'
        within '[data-meeting-analysis-composer-target="titleBox"]' do
          click_button 'Als Vorlage speichern'
        end
        expect(page).to have_text('Vorlage für die Organisation gespeichert')
        expect(in_org { AnalysisPrompt.find_by!(title: 'Mit Verantwortlichen').prompt_text }).to eq(field.value)
        expect(page).to have_css('textarea', count: 1)
        field.send_keys(:enter)
      end
      expect(page).to have_css('#assistant-panel-chat')
      chat = in_org { Chat.order(:created_at).last }
      expect(in_org { MeetingAnalysis.count }).to eq(0)
      instruction = in_org { chat.chatposts.first.analysis_context['instruction'] }
      expect(instruction).to eq('Nur verbindliche Entscheidungen mit Verantwortlichen.')
      # Two completed results: saving the first must not silently take the latest one.
      chosen = in_org do
        citation = Lalabase::Citations.meeting(first).stringify_keys
        create(:chatpost, chat: chat, organisation: organisation, role: :assistant, model_used: 'test',
                          content: "## Entscheidungen\n\nStart im Mai. [1]", source_citations: [citation],
                          analysis_context: { 'meeting_ids' => [first.id], 'instructions' => [instruction], 'provenance' => [citation] })
      end
      in_org { create(:chatpost, chat: chat, role: :assistant, content: 'Andere Antwort', model_used: 'test') }
      in_org { Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Eine noch wartende Frage' }) }
      visit organisation_project_meetings_path(organisation, project, meeting_id: second.id, assistant_chat_id: chat.id, viewport: width < 1024 ? 'mobile' : nil)
      page.refresh
      expect(page).to have_css('#assistant-panel-chat')
      within '#assistant_panel' do
        find('textarea').set('Mein Überarbeitungsentwurf.')
        within "#chatpost_#{chosen.id}" do
          click_button 'Überarbeiten'
        end
        expect(find('textarea').value).to eq('Mein Überarbeitungsentwurf.')
        expect(page).to have_css('textarea', count: 1)
        within '[data-meeting-analysis-composer-target="revision"]' do
          expect(page).to have_text('Überarbeitung der ausgewählten Antwort')
          click_button 'Abbrechen'
        end
        expect(find('textarea').value).to eq('Mein Überarbeitungsentwurf.')
        within "#chatpost_#{chosen.id}" do
          click_button 'Überarbeiten'
        end
        find('textarea').set('Mach das bitte kürzer.')
        # Navigation while another answer is outstanding replaces the frame.
        # Wait for that replacement; checking the old permanent DOM would pass
        # even when only the text, but no revision binding, gets restored.
        page.execute_script(<<~JS)
          window.__revisionFrameLoads = 0
          document.addEventListener('turbo:frame-load', event => {
            if (event.target.id === 'assistant_panel_body') window.__revisionFrameLoads += 1
          })
          Turbo.visit('#{organisation_project_meetings_path(organisation, project, meeting_id: first.id, viewport: width < 1024 ? 'mobile' : nil)}')
        JS
      end
      expect(page).to have_current_path(organisation_project_meetings_path(organisation, project), ignore_query: true)
      expect(page).to have_css('#meeting-header', text: 'Planungsrunde')
      Timeout.timeout(Capybara.default_max_wait_time) do
        sleep 0.05 until page.evaluate_script('window.__revisionFrameLoads') >= 1
      end
      find('#meeting-header [data-controller="assistant-trigger"]').click if width < 1024
      within '#assistant_panel' do
        expect(find('textarea').value).to eq('Mach das bitte kürzer.')
        expect(page).to have_css('[data-meeting-analysis-composer-target="revision"]', text: 'Überarbeitung der ausgewählten Antwort')
        expect(find('[data-meeting-analysis-composer-target="revisionId"]', visible: :all).value).to eq(chosen.id)
        expect(find('[data-meeting-analysis-composer-target="revisionKey"]', visible: :all).value).to eq(chosen.analysis_answer_key)
        find('textarea').send_keys(:enter)
        expect(page).to have_no_css('[data-meeting-analysis-composer-target="revision"]')
      end
      revision = in_org { chat.chatposts.not_assistant.order(:created_at).last }
      expect(revision.analysis_context).to include('revision_answer_id' => chosen.id, 'revision_answer_key' => chosen.analysis_answer_key)
      expect(in_org { MeetingAnalysis.count }).to eq(0)
      within "#chatpost_#{chosen.id}" do
        find('summary', text: 'Als Analyse speichern').click
        expect(find('select[name="meeting_id"]').value).to eq(first.id)
        fill_in 'Titel', with: 'Festgehaltene Entscheidungen'
        page.save_screenshot(Rails.root.join("tmp/screenshots/assistant-analysis-#{width}.png")) # rubocop:disable Lint/Debugger -- retained desktop/mobile QA evidence
        if width == 390
          permission = in_org { ProjectPermission.find_by!(user: user, project: project) }
          in_org { permission.update!(meetings_access: 'read_only') }
          click_button 'Privat speichern'
          expect(page).to have_text('Diese Antwort kann nicht gespeichert werden')
          expect(find('input[name="title"]').value).to eq('Festgehaltene Entscheidungen')
          expect(find('select[name="meeting_id"]').value).to eq(first.id)
          in_org { permission.update!(meetings_access: 'read_write') }
        end
        click_button 'Privat speichern'
        expect(page).to have_text('Privat am Meeting gespeichert')
      end
      within "#analyses_meeting_#{first.id}" do
        expect(page).to have_css('[id^="meeting_analysis_"]', text: 'Festgehaltene Entscheidungen', visible: :all)
      end
      page.refresh
      within "#chatpost_#{chosen.id}" do
        expect(page).to have_text('Privat am Meeting gespeichert')
        expect(page).to have_no_css('summary', text: 'Als Analyse speichern')
        click_link 'Analyse öffnen'
      end
      expect(page).to have_css('#meeting-header', text: 'Planungsrunde')
      analysis = in_org { MeetingAnalysis.find_by!(prompt_title: 'Festgehaltene Entscheidungen') }
      expect(analysis.content).to eq(chosen.content)
      expect(analysis).to have_attributes(is_private: true, include_in_search: false)
      expect(page).to have_css("#meeting_analysis_#{analysis.id} details[open]")
      expect(URI.parse(page.current_url).query.to_s).not_to include('analysis_id=')
      within "#meeting_analysis_#{analysis.id}" do
        find('details summary', match: :first).click
        expect(page).to have_no_css('details[open]')
      end
      page.execute_script('const row = document.getElementById(arguments[0]); row.replaceWith(row.cloneNode(true))', "meeting_analysis_#{analysis.id}")
      expect(page).to have_no_css("#meeting_analysis_#{analysis.id} details[open]")
      expect(page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')).to be true
    ensure
      page.save_screenshot(Rails.root.join("tmp/screenshots/assistant-analysis-end-#{width}.png")) # rubocop:disable Lint/Debugger -- retained desktop/mobile QA evidence
      page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
      page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    end
  end
  it 'keeps existing-chat templates compact, requires a target choice and manages templates in the assistant' do
    page.driver.browser.manage.window.resize_to(1280, 900)
    chat = in_org do
      create(:chat, organisation: organisation, user: user,
                    scope_references: [first, second].map { |meeting| { type: 'Meeting', id: meeting.id } })
    end
    answer = in_org do
      citations = [first, second].map { |meeting| Lalabase::Citations.meeting(meeting).stringify_keys }
      create(:chatpost, chat: chat, role: :assistant, model_used: 'test', content: 'Vergleich der Entscheidungen.',
                        source_citations: citations,
                        analysis_context: { meeting_ids: [first.id, second.id], instructions: ['Vergleiche Entscheidungen.'], provenance: citations })
    end
    visit organisation_project_meetings_path(organisation, project, meeting_id: second.id, assistant_chat_id: chat.id)
    expect(page).to have_css('#assistant-panel-chat')
    within '#assistant_panel' do
      expect(page).to have_no_css('[data-meeting-analysis-composer-target="tools"][open]')
      find('summary', text: 'Meeting analysieren').click
      find('textarea').set('Vorhandener Entwurf.')
      click_button 'Vorlage wählen'
      click_button 'Entscheidungsprotokoll'
      expect(find('textarea').value).to eq("Vorhandener Entwurf.\n\nFasse verbindliche Entscheidungen zusammen.")
      within "#chatpost_#{answer.id}" do
        find('summary', text: 'Als Analyse speichern').click
        expect(find('select[name="meeting_id"]').value).to eq('')
        select first.one_line_title(max: 120), from: 'Meeting'
        click_button 'Privat speichern'
        expect(page).to have_text('Privat am Meeting gespeichert')
      end
      expect(in_org { MeetingAnalysis.last.meeting_id }).to eq(first.id)
      # Library management remains in the same assistant surface.
      in_org { [first, second].each { |meeting| meeting.update!(notes: '') } }
      click_button 'Vorlage wählen'
      click_button 'Vorlagen verwalten'
      expect(page).to have_button('Löschen: Entscheidungsprotokoll')
      accept_confirm { click_button 'Löschen: Entscheidungsprotokoll' }
      expect(page).to have_text('Vorlage gelöscht.')
      expect(page).to have_no_button('Entscheidungsprotokoll')
    end
    expect(in_org { AnalysisPrompt.exists?(title: 'Entscheidungsprotokoll') }).to be(false)
    expect(page).to have_no_css('#meeting_analyses_lane')
  end
  it 'keeps permission-gated template controls hidden in the built stylesheet' do
    in_org { ProjectPermission.find_by!(project: project, user: user).update!(meetings_access: 'read_only') }
    chat = in_org { create(:chat, organisation: organisation, user: user, scope_references: [{ type: 'Meeting', id: first.id }]) }
    visit organisation_project_meetings_path(organisation, project, meeting_id: first.id, assistant_chat_id: chat.id)
    within '#assistant_panel' do
      find('summary', text: 'Meeting analysieren').click
      expect(page).to have_button('Entscheidungen zusammenfassen')
      expect(page).to have_no_button('Vorlage wählen')
      expect(page).to have_no_button('Vorlagen verwalten')
      expect(page).to have_no_button('Als Vorlage speichern')
      # Opening the picker programmatically must not let display utilities reveal
      # its separately permission-gated management link.
      page.execute_script(%q{document.querySelector('[data-meeting-analysis-composer-target="picker"]').hidden = false})
      expect(page).to have_no_button('Vorlagen verwalten')
    end
  end
end
