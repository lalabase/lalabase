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
    page.driver.browser.manage.window.resize_to(1440, 900)
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def open_at(window_width)
    page.driver.browser.manage.window.resize_to(window_width, 900)
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
    open_panel
  end

  def open_panel
    within("#meeting-references-#{ticket.id}") { click_link 'Planning call' }
    expect(page).to have_css('aside.column.panel h2', text: 'Planning call')
  end

  def stage = find('.layout')['data-meeting-panel-stage']

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

  # Wait for the grid's transition to settle before measuring.
  def settled
    sleep 0.5
  end

  context 'without the assistant' do
    it 'shows list, ticket and meeting side by side on a wide grid' do
      open_at(1600)

      expect(page).to have_css('.layout[data-meeting-panel-stage="wide"]')
      settled
      expect(widths[:list]).to be >= 320
      expect(widths[:ticket]).to be >= 360
      expect(widths[:meeting]).to be_between(320, 480)
      expect(page).to have_no_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
      expect(page).to have_no_css('.lane-split', visible: :visible)
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
      expect(stage_tab('Meeting')['aria-selected']).to eq('true')
      expect(page).to have_css('aside.column.panel h2', text: 'Planning call', visible: :visible)
      expect(page).to have_no_css("#ticket-content-#{ticket.id}", visible: :visible)

      scroll('.layout .column.panel', to: 900)
      stage_tab("Ticket ##{ticket.number}").click
      expect(stage_tab("Ticket ##{ticket.number}")['aria-selected']).to eq('true')
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
      expect(page).to have_no_css('aside.column.panel h2', visible: :visible)
      # The tab bar stays, so there is a way back.
      expect(page).to have_css('.ticket-meeting-panel__stage-tabs', visible: :visible)

      scroll('.layout .column.content', to: 700)
      stage_tab('Meeting').click
      expect(page).to have_css('aside.column.panel h2', visible: :visible)
      expect(scroll_top('.layout .column.panel')).to be_within(2).of(900)

      stage_tab("Ticket ##{ticket.number}").click
      expect(page).to have_css("#ticket-content-#{ticket.id}", visible: :visible)
      expect(scroll_top('.layout .column.content')).to be_within(2).of(700)
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
      page.driver.browser.manage.window.resize_to(1280, 900)
      visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      find('#assistant-panel-trigger').click
      expect(page).to have_css('body.assistant-panel-open')
      open_panel

      expect(page).to have_css('.layout[data-meeting-panel-stage="narrow"]')
      expect(page).to have_css('.ticket-meeting-panel__stage-tabs', visible: :visible)
      expect(stage_tab('Meeting')['aria-selected']).to eq('true')
      expect(assistant_open?).to be(true)
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
