# frozen_string_literal: true

require 'rails_helper'

# The assistant offers the ticket AND the meeting beside it (doc/ticket_meeting_panel_plan.md,
# S3), clicked for real. Until S3 the assistant read only the first object a page named, so
# the meeting in the panel was never on offer. The strip offers them one after the other in
# page order, and a closed panel offers nothing.
RSpec.describe 'Assistant beside the ticket and its meeting', type: :system do
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    driven_by :selenium_chrome_headless_full
    page.driver.browser.manage.window.resize_to(1600, 900)
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  # After the before block above: they need its tenant.
  let!(:ticket) { create(:ticket, project: project, title: 'Navigation for the start page', creator: user) }
  let!(:meeting) do
    create(:meeting, project: project, title: 'Weekly with the client', creator: user, occurred_at: 2.days.ago,
                     notes: 'Five menu entries.').tap do |m|
      m.outgoing_references.create!(organisation: organisation, target: ticket, target_title_snapshot: ticket.display_title)
    end
  end

  after do
    page.driver.browser.manage.window.resize_to(1440, 900)
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def offer = page.find('[data-assistant-panel-target="offer"]', visible: :all)
  def offered = offer['data-context-id']
  def offer_take = page.find('[data-assistant-panel-target="offerTake"]')

  def collected_keys
    page.evaluate_script(
      "(document.querySelector('#assistant_panel [data-reference-keys]')?.dataset.referenceKeys || '').split(' ').filter(Boolean)"
    )
  end

  def open_ticket_with_assistant_and_meeting
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
    expect(page).to have_css("#ticket-content-#{ticket.id}")
    find('#assistant-panel-trigger').click
    expect(page).to have_css('body.assistant-panel-open')
    within("#meeting-references-#{ticket.id}") { click_link 'Weekly with the client' }
    expect(page).to have_css('aside.column.panel h2', text: 'Weekly with the client')
  end

  it 'offers the ticket, then the meeting beside it, and collects both' do
    open_ticket_with_assistant_and_meeting

    expect(page).to have_css(%([data-assistant-panel-target="offer"][data-context-id="Ticket:#{ticket.id}"]))
    offer_take.click
    expect(page).to have_css(%([data-assistant-panel-target="offer"][data-context-id="Meeting:#{meeting.id}"]))
    expect(collected_keys).to eq(["Ticket:#{ticket.id}"])

    offer_take.click
    expect(page).to have_css('[data-assistant-panel-target="offer"].hidden', visible: :all)
    expect(collected_keys).to eq(["Ticket:#{ticket.id}", "Meeting:#{meeting.id}"])
  end

  it 'offers no meeting once the panel is closed' do
    open_ticket_with_assistant_and_meeting
    expect(page).to have_css(%([data-assistant-panel-target="offer"][data-context-id="Ticket:#{ticket.id}"]))
    offer_take.click
    expect(page).to have_css(%([data-assistant-panel-target="offer"][data-context-id="Meeting:#{meeting.id}"]))

    find('aside.column.panel .panel-close').click
    expect(page).to have_css('.layout.hide-panel')

    expect(page).to have_css('[data-assistant-panel-target="offer"].hidden', visible: :all)
    expect(offered).to be_nil
  end
end
