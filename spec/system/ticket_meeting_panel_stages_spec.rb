# frozen_string_literal: true

require 'rails_helper'

# The meeting beside the ticket in three stages, measured in a real browser at real grid
# widths (doc/ticket_meeting_panel_plan.md, S2). The stage follows the GRID, so the
# assistant beside the page changes it without the window changing; the assistant is never
# closed for it. Widths (window 1440 x 900 and a 256px sidebar, measured 2026-10-23):
#
#   window  grid  stage, without the assistant  | with it
#   1600    1296  wide                           | medium (L12: the list yields to it)
#   1200     896  medium                         |
#   1280                                         | narrow
#   1024     720  narrow                         |
#
# The boundaries themselves (728 and 1104 px of grid) are pinned by the node tests of
# lib/lane/meeting_panel_stage; this spec proves the stylesheet lays out what they decide.
RSpec.describe 'Meeting beside the ticket, by the width of the grid', type: :system do
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    driven_by :selenium_chrome_headless_full
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  # After the before block above: they need its tenant.
  let!(:ticket) do
    create(:ticket, project: project, title: 'Ticket with a long story', creator: user,
                    content: Array.new(80) { |i| "<p>Ticket line #{i}.</p>" }.join)
  end
  let!(:meeting) do
    create(:meeting, project: project, title: 'Planning call', creator: user, occurred_at: 2.days.ago,
                     notes: Array.new(80) { |i| "Meeting note #{i}." }.join("\n\n")).tap do |m|
      m.outgoing_references.create!(organisation: organisation, target: ticket, target_title_snapshot: ticket.display_title)
    end
  end

  after do
    # The window is reused by the next example, and with it this origin's storage: a
    # hidden list or a remembered split must not travel.
    begin
      page.execute_script('sessionStorage.clear(); localStorage.clear()')
    rescue StandardError
      nil
    end
    page.driver.browser.manage.window.resize_to(1440, 900)
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def visit_ticket_at(window_width)
    page.driver.browser.manage.window.resize_to(window_width, 900)
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
    expect(page).to have_css("#ticket-content-#{ticket.id}")
  end

  def open_at(window_width)
    visit_ticket_at(window_width)
    open_panel
  end

  def open_panel
    within("#meeting-references-#{ticket.id}") { click_link 'Planning call' }
    expect(page).to have_css('aside.column.panel h2', text: 'Planning call')
  end

  # The panel's frame loads it, without a click on a link: the focus stays where it is.
  def load_panel(meeting_id)
    url = organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting_id)
    page.execute_script("document.getElementById('ticket_meeting_panel').src = #{url.to_json}")
  end

  # A control of the ticket the reader has moved on to, the first VISIBLE one: the first
  # in the markup is the phone's back button, hidden here. Until 2026-10-29 the focus test
  # focused that one, which did nothing, and the focus stayed on the link that opened the
  # panel: the test ran on the opening, not on work in the ticket.
  def focus_ticket_control
    find('#ticket-header').first('a[href], button').execute_script('this.focus()')
    expect(page).to have_css('#ticket-header :focus')
  end

  def stage = find('.layout')['data-meeting-panel-stage']

  def rect(selector, side)
    page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().#{side}")
  end

  def width(selector)
    page.evaluate_script("Math.round(document.querySelector(#{selector.to_json}).getBoundingClientRect().width)")
  end

  def widths = { list: width('.layout .column.list'), ticket: width('.layout .column.content'), meeting: width('.layout .column.panel') }

  def scroll_top(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).scrollTop")

  def scroll(selector, to:)
    page.execute_script("document.querySelector(#{selector.to_json}).scrollTop = #{to}")
  end

  def stage_tab(name)
    find('.ticket-meeting-panel__stage-tab', text: name)
  end

  def assistant_open? = page.evaluate_script('document.body.classList.contains("assistant-panel-open")')

  # Measure only a grid at rest: its tracks animate (layout.css), and while the
  # assistant opens or closes the grid's width changes over several frames, each of
  # which re-sets the split and restarts that animation. A fixed sleep measured one
  # of those frames.
  def settled
    probe = "(() => { const g = document.querySelector('.layout'); " \
            'return [g.getAnimations().length, Math.round(g.getBoundingClientRect().width)] })()'
    previous = nil
    40.times do
      state = page.evaluate_script(probe)
      break if state.first.zero? && state == previous

      previous = state
      sleep 0.1
    end
  end

  context 'without the assistant' do
    it 'shows list, ticket and meeting side by side on a wide grid' do
      other = create(:ticket, project: project, title: 'Another ticket on the list', creator: user)
      open_at(1600)

      expect(page).to have_css('.layout[data-meeting-panel-stage="wide"]')
      settled
      expect(widths[:list]).to be >= 320
      expect(widths[:ticket]).to be >= 360
      expect(widths[:meeting]).to be_between(320, 480)
      expect(page).to have_no_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
      expect(page).to have_no_css('.lane-split', visible: :visible)
      # The list keeps its channel: the ticket does not take it back as it does when
      # the list has yielded.
      expect(rect('.layout .column.content', 'left') - rect('.layout .column.list', 'right')).to be_within(1).of(24)

      # And the list is a list, not a yielded one under the ticket: its rows take a click.
      find(%([data-list-row-id-value="#{other.id}"])).click
      expect(page).to have_css("#ticket-content-#{other.id}")
    end

    it 'lets the list yield on a medium grid' do
      open_at(1200)

      expect(page).to have_css('.layout[data-meeting-panel-stage="medium"]')
      settled
      expect(widths[:list]).to eq(0)
      expect(widths[:ticket]).to be >= 360
      expect(widths[:meeting]).to be_between(320, 480)
      expect(page).to have_no_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
    end

    it 'turns ticket and meeting into two tabs on a narrow grid, each keeping its scroll position' do
      open_at(1024)

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      settled
      expect(widths[:ticket]).to eq(width('.layout'))
      expect(widths[:meeting]).to eq(width('.layout'))
      # The meeting first: it was opened last (F6).
      expect(stage_tab('Meeting')['aria-pressed']).to eq('true')
      expect(page).to have_css('aside.column.panel h2', text: 'Planning call', visible: :visible)
      expect(page).to have_no_css("#ticket-content-#{ticket.id}", visible: :visible)

      scroll('.layout .column.panel', to: 900)
      stage_tab("Ticket ##{ticket.number}").click
      expect(stage_tab("Ticket ##{ticket.number}")['aria-pressed']).to eq('true')
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
      expect(page).to have_no_css('aside.column.panel h2', visible: :visible)
      # The tab bar stays, so there is a way back.
      expect(page).to have_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
      # It lies over the top of the ticket's cell; the ticket begins below it.
      scroll('.layout .column.content', to: 0)
      expect(rect('#ticket-header', 'top')).to be >= rect('.ticket-meeting-panel__stage-tabs', 'bottom') - 1

      scroll('.layout .column.content', to: 700)
      stage_tab('Meeting').click
      expect(page).to have_css('aside.column.panel h2', visible: :visible)
      expect(scroll_top('.layout .column.panel')).to be_within(2).of(900)

      stage_tab("Ticket ##{ticket.number}").click
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
      expect(scroll_top('.layout .column.content')).to be_within(2).of(700)

      # The meeting still sits 900px down behind the ticket. Its close control must
      # stay in the visible tab bar, without scrolling either lane back to the top.
      expect(page).to have_css('aside.column.panel .panel-close', obscured: false)
      find('aside.column.panel .panel-close').click
      expect(page).to have_css('.layout.hide-panel')
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
      # A closed panel leaves no stage behind for the stylesheet and the assistant to read.
      expect(page).to have_no_css('.layout[data-meeting-panel-stage], .layout[data-meeting-panel-tab]')
    end

    it 'keeps a hidden list hidden at the wide stage, with no channel before the ticket' do
      page.driver.browser.manage.window.resize_to(1600, 900)
      visit organisation_project_tickets_path(organisation, project)
      page.execute_script("sessionStorage.setItem('layoutState', JSON.stringify({ categories: false, list: false, content: true, panel: false }))")
      visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      expect(page).to have_css('.layout.hide-list')
      open_panel

      expect(page).to have_css('.layout[data-meeting-panel-stage="wide"]')
      settled
      expect(widths[:list]).to eq(0)
      expect(page.evaluate_script("document.querySelector('.layout .column.content').getBoundingClientRect().left"))
        .to be_within(1).of(page.evaluate_script("document.querySelector('.layout').getBoundingClientRect().left"))
    end

    it 'offers the way back to the ticket when the meeting is not available on a narrow grid' do
      visit_ticket_at(1024)
      load_panel(SecureRandom.uuid)

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]:not(.hide-panel)')
      expect(page).to have_text(I18n.t('views.organisations.tickets.meeting_panel.unavailable'))
      stage_tab('Ticket').click
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
    end

    it 'keeps the ticket in front when the grid narrows while the ticket has the focus' do
      open_at(1200)
      expect(page).to have_css('.layout[data-meeting-panel-stage="medium"]')
      focus_ticket_control
      focused = page.evaluate_script('document.activeElement.outerHTML')

      page.driver.browser.manage.window.resize_to(1024, 900)

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      expect(stage_tab("Ticket ##{ticket.number}")['aria-pressed']).to eq('true')
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
      expect(page.evaluate_script('document.activeElement.outerHTML')).to eq(focused)
    end

    # The opening is excused for the link that loads the panel, and for nothing else: a
    # panel that arrives while the focus is on another control of the ticket (loaded
    # here without a click) leaves the ticket in front when the grid narrows.
    it 'keeps the ticket in front when the focus was in the ticket before the panel came' do
      visit_ticket_at(1200)
      focus_ticket_control
      load_panel(meeting.id)
      expect(page).to have_css('.layout[data-meeting-panel-stage="medium"]:not(.hide-panel)')
      expect(page).to have_css('#ticket-header :focus')

      page.driver.browser.manage.window.resize_to(1024, 900)

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      expect(stage_tab("Ticket ##{ticket.number}")['aria-pressed']).to eq('true')
    end

    # And the excuse ends when the focus leaves that link: whoever comes back to it
    # later, by keyboard, is moving through the ticket.
    it 'keeps the ticket in front when the focus has left the opening link and come back' do
      open_at(1200)
      expect(page).to have_css('.layout[data-meeting-panel-stage="medium"]')
      link = "#meeting-references-#{ticket.id} a.meeting-reference--panel"
      expect(page).to have_css("#{link}:focus")
      focus_ticket_control
      find(link).execute_script('this.focus()')
      expect(page).to have_css("#{link}:focus")

      page.driver.browser.manage.window.resize_to(1024, 900)

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      expect(stage_tab("Ticket ##{ticket.number}")['aria-pressed']).to eq('true')
    end
  end

  # The split follows the GRID's width as well: the assistant changes it without the
  # window changing. Before, the split was computed from the window's resize only, and a
  # list remembered at 70 % came back at whatever the narrower grid had allowed.
  context 'the split between list and lane' do
    it 'takes its remembered share of the grid again when the assistant closes' do
      page.driver.browser.manage.window.resize_to(1600, 900)
      visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      page.execute_script("localStorage.setItem('lalabase:lane-split:tickets', '0.7')")
      find('#assistant-panel-trigger').click
      expect(page).to have_css('body.assistant-panel-open')
      visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      expect(page).to have_css('body.assistant-panel-open')

      find('#assistant-panel-trigger').click
      expect(page).to have_no_css('body.assistant-panel-open')
      settled

      grid = width('.layout')
      expect(widths[:list]).to be_within(2).of((grid * 0.7).round)
    end
  end

  context 'with the assistant' do
    it 'moves to the next stage when the assistant opens, and never closes it' do
      open_at(1600)
      expect(page).to have_css('.layout[data-meeting-panel-stage="wide"]')

      find('#assistant-panel-trigger').click
      expect(page).to have_css('body.assistant-panel-open')

      expect(page).to have_css('.layout[data-meeting-panel-stage="medium"]')
      settled
      expect(widths[:list]).to eq(0)
      expect(widths[:ticket]).to be >= 360
      expect(widths[:meeting]).to be_between(320, 480)

      find('body').send_keys(:escape)
      expect(page).to have_css('.layout.hide-panel')
      expect(assistant_open?).to be(true)
    end

    it 'shows the tabs on a grid the assistant has made narrow' do
      visit_ticket_at(1280)
      find('#assistant-panel-trigger').click
      expect(page).to have_css('body.assistant-panel-open')
      open_panel

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      expect(page).to have_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
      expect(stage_tab('Meeting')['aria-pressed']).to eq('true')
      expect(assistant_open?).to be(true)
    end

    # The assistant pushes the page aside in a transition of <main> (half a second), so
    # a meeting opened right after it opens on a grid that is still medium and turns
    # narrow under it. The focus is then still on the link just clicked, in the ticket:
    # that is opening the meeting, not working in the ticket, and the meeting stays in
    # front (F6). Until 2026-10-29 the ticket came to the front in about one CI run in
    # four. Here the transition is held at its start while the panel opens and then
    # finished at once, so no clock decides the race.
    it 'keeps the meeting in front when the grid narrows while the panel is still opening' do
      visit_ticket_at(1280)
      main = "document.querySelector('.mobile-app-screen > main')"
      page.execute_script("#{main}.style.transitionDuration = '600s'")
      find('#assistant-panel-trigger').click
      # The composer takes the focus once its frame has loaded, and nothing moves it after that.
      expect(page).to have_css('#assistant_panel [data-neo-chat-composer-target="field"]:focus')
      within("#meeting-references-#{ticket.id}") { click_link 'Planning call' }
      expect(page).to have_css('.layout[data-meeting-panel-stage="medium"]:not(.hide-panel)')
      expect(page).to have_css("#meeting-references-#{ticket.id} a.meeting-reference--panel:focus")

      page.execute_script("#{main}.getAnimations().forEach((animation) => animation.finish())")

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      expect(stage_tab('Meeting')['aria-pressed']).to eq('true')
      expect(page).to have_css('aside.column.panel h2', text: 'Planning call', visible: :visible)
    end
  end

  context 'on the board' do
    before do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ] })
      ticket.update!(custom_attributes: { 'status' => 'Neu' })
      ViewConfiguration.create!(user: user, project: project, organisation: organisation,
                                view_type: 'tickets', view_mode: 'kanban',
                                table_columns: %w[number title], header_columns: %w[assignees],
                                list_columns: { 'cells' => [], 'metadata' => [] })
    end

    it 'follows the same stages' do
      open_at(1600)
      expect(page).to have_css('.layout.kanban-layout[data-meeting-panel-stage="wide"]')
      settled
      expect(widths[:list]).to be >= 320

      page.driver.browser.manage.window.resize_to(1024, 900)
      expect(page).to have_css('.layout.kanban-layout[data-meeting-panel-stage="narrow"]')
      expect(page).to have_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
    end
  end
end
