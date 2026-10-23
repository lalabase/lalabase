# frozen_string_literal: true

require 'rails_helper'

# The meeting beside the ticket, clicked for real (doc/ticket_meeting_panel_plan.md, S1).
# What markup cannot prove: the panel opens from the ticket's meetings section without a
# page change, the list yields while it is open, Escape closes the panel before the lane,
# the ✕ closes and empties it, and another ticket in the lane closes it (F3). And the inbox
# pane shows the meeting as text, the one form its frame names.
RSpec.describe 'Meeting beside the ticket', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:mp) { 'views.organisations.tickets.meeting_panel' }

  before do
    driven_by :selenium_chrome_headless_full
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                        active: true)
    sign_in user
  end

  # After the before block above: they need its tenant.
  let!(:ticket) { create(:ticket, project: project, title: 'Ticket beside a meeting', creator: user) }
  let!(:sibling) { create(:ticket, project: project, title: 'Sibling from the meeting', creator: user) }
  let!(:meeting) do
    create(:meeting, project: project, title: 'Planning call', creator: user, occurred_at: 2.days.ago,
                     notes: 'Agreed to ship on Friday.').tap do |m|
      [ticket, sibling].each do |target|
        m.outgoing_references.create!(organisation: organisation, target: target, target_title_snapshot: target.display_title)
      end
    end
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def lane_path(of = ticket)
    organisation_project_tickets_path(organisation, project, ticket_id: of.id)
  end

  def mark_page
    page.execute_script('window.__meetingPanelPageMark = true')
  end

  def same_page?
    page.evaluate_script('window.__meetingPanelPageMark === true')
  end

  def width_of(selector)
    page.evaluate_script("Math.round(document.querySelector(#{selector.to_json}).getBoundingClientRect().width)")
  end

  def open_panel
    within("#meeting-references-#{ticket.id}") { click_link 'Planning call' }
    expect(page).to have_css('aside.column.panel h2', text: 'Planning call')
  end

  def expect_panel_closed
    expect(page).to have_css('.layout.hide-panel')
    expect(page).to have_no_css('aside.column.panel h2')
    expect(page.evaluate_script("document.getElementById('ticket_meeting_panel').childElementCount")).to eq(0)
  end

  it 'opens the meeting beside the ticket, the list yields, and Escape closes the panel before the lane' do
    visit lane_path
    expect(page).to have_css("#ticket-content-#{ticket.id}")
    mark_page
    expect(width_of('.layout .column.list')).to be > 200

    open_panel

    expect(same_page?).to be(true)
    expect(page).to have_css("#ticket-content-#{ticket.id}")
    expect(page).to have_text('Agreed to ship on Friday.')
    expect(width_of('.layout .column.list')).to eq(0)
    expect(width_of('.layout .column.panel')).to be_between(320, 480)
    expect(page).to have_current_path(lane_path)

    find('body').send_keys(:escape)
    expect_panel_closed
    expect(page).to have_css("#ticket-content-#{ticket.id}")
    expect(width_of('.layout .column.list')).to be > 200

    find('body').send_keys(:escape)
    expect(page).to have_css('.layout.hide-content')
  end

  it 'closes and empties the panel with its ✕' do
    visit lane_path
    open_panel

    find('aside.column.panel .panel-close').click

    expect_panel_closed
    expect(page).to have_css("#ticket-content-#{ticket.id}")
  end

  it 'closes the panel when the lane shows another ticket' do
    visit lane_path
    mark_page
    open_panel

    within('aside.column.panel') { click_link 'Sibling from the meeting' }

    expect(page).to have_css("#ticket-content-#{sibling.id}")
    expect_panel_closed
    expect(same_page?).to be(true)
    expect(page).to have_current_path(lane_path(sibling))
  end

  it 'starts the ticket at the edge of the grid while the list has yielded' do
    visit lane_path
    open_panel
    sleep 0.5 # the grid's transition

    grid_left = page.evaluate_script("document.querySelector('.layout').getBoundingClientRect().left")
    ticket_left = page.evaluate_script("document.querySelector('.layout .column.content').getBoundingClientRect().left")
    expect(ticket_left).to be_within(1).of(grid_left)
  end

  it 'marks the row of a ticket opened from the panel, not the link' do
    visit lane_path
    open_panel

    within('aside.column.panel') { click_link 'Sibling from the meeting' }

    expect(page).to have_css("#ticket-content-#{sibling.id}")
    expect(page).to have_css(%([data-list-row-id-value="#{sibling.id}"].selected-row), visible: :all)
    expect(page).to have_no_css(%([data-list-row-id-value="#{ticket.id}"].selected-row), visible: :all)
  end

  it 'does not open a meeting that arrives after its ticket has left the lane' do
    visit lane_path
    find(%([data-list-row-id-value="#{sibling.id}"])).click
    expect(page).to have_css("#ticket-content-#{sibling.id}")

    url = organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting.id)
    page.execute_script("document.getElementById('ticket_meeting_panel').src = #{url.to_json}")
    sleep 1

    expect_panel_closed
    expect(page).to have_css("#ticket-content-#{sibling.id}")
  end

  it 'stays closed when the answer to a request still running arrives after the close' do
    visit lane_path
    open_panel

    url = organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting.id)
    page.execute_script("document.getElementById('ticket_meeting_panel').src = #{"#{url}&again=1".to_json};" \
                        "document.querySelector('aside.column.panel .panel-close').click()")
    sleep 1

    expect_panel_closed
  end

  it 'closes the panel when the lane closes' do
    visit lane_path
    open_panel

    within('#ticket-header') { find('[data-action="click->layout-toggle#closeContent"]', match: :first).click }

    expect(page).to have_css('.layout.hide-content')
    expect_panel_closed
  end

  it 'shows the meeting as text without a link in the inbox pane' do
    notification = create(:notification, recipient: user, organisation: organisation, project: project,
                                         notifiable: ticket, channel: 'in_app', state: :delivered)
    visit organisation_notifications_path(organisation, notification: notification.id)

    within("#meeting-references-#{ticket.id}") do
      expect(page).to have_css('span.meeting-reference--text', text: 'Planning call', visible: :visible)
      expect(page).to have_no_link('Planning call')
    end
  end

  it 'leaves for the meetings page from the phone layout' do
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id, viewport: 'mobile')

    within("#meeting-references-#{ticket.id}") do
      expect(page).to have_css('a.meeting-reference--page', text: 'Planning call', visible: :visible)
      expect(page).to have_no_css('a.meeting-reference--panel', visible: :visible)
    end
  end
end
