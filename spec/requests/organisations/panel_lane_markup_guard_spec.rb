# frozen_string_literal: true

require 'rails_helper'

# Guard for the third-lane markup after the chat->panel rename (S2b, PR #598
# second review): a HALF rename is silent -- a stale class like `hide-chat`
# renders fine, throws nothing, and simply stops matching every CSS rule, so
# the lane stands permanently open with an invisible close button. No request
# spec looked at these classes, and the mutation probes proved it: reverting
# single call sites kept everything green. The tickets pages lost the lane with
# the ticket chat (S4-T1), the knowledge page its chat placeholder on 10.09.2026
# and the meetings page its analyses lane in #817. Since
# doc/ticket_meeting_panel_plan.md (S1) the ticket pages fill it again, with the
# meeting beside the ticket: ONE lane, closed on arrival, holding nothing but the
# empty frame the meeting loads into, and its own close button as the only
# trigger. That shape is pinned exactly, because an empty aside with a close
# button is otherwise the leftover nobody notices in a request spec; the other
# grid pages stay pinned in the negative.
RSpec.describe 'Panel lane markup (rename guard)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def page
    Capybara.string(response.body)
  end

  # The lane of the meeting beside the ticket, as the ticket page renders it before
  # anything was opened: closed, empty but for its frame, one trigger, its own ✕.
  def expect_closed_meeting_lane
    expect(page).to have_css('div.layout.two-column.hide-panel')
    lane = page.find('div.layout.two-column > aside.column.panel', visible: :all)
    expect(lane.all('*', visible: :all).map(&:tag_name)).to eq(%w[button i turbo-frame])
    expect(lane).to have_css('turbo-frame#ticket_meeting_panel:empty', visible: :all)
    # ... and no other trigger: the header "Chat" button survived the first cut and
    # toggled hide-panel on a grid with no aside, collapsing the list into an empty track.
    expect(page).to have_css('[data-action~="click->layout-toggle#togglePanel"]', count: 1, visible: :all)
    expect(lane).to have_css('button.panel-close[data-action~="click->layout-toggle#togglePanel"]', visible: :all)
  end

  it 'renders on the tickets LIST only the closed lane of the meeting beside the ticket' do
    get organisation_project_tickets_path(organisation, project)

    expect(response).to have_http_status(:ok)
    # Shape, not class: the list and the meeting lane are the ONLY asides, so a
    # re-added lane under another class name would fail here too.
    expect(page).to have_css('div.layout.two-column > aside', count: 2)
    expect_closed_meeting_lane
  end

  # The board is on the same lane grid as the table since
  # doc/kanban_ticket_als_bahn_plan.md (S1a): the exact children of the grid,
  # by tag and class, and their count. The slide-over rendered again, or a
  # fourth child of any class, fails here.
  it 'renders the board on the lane grid: list column, split handle, lane, and the closed meeting lane' do
    ViewConfiguration.create!(
      user: user, project: project, organisation: organisation,
      view_type: 'tickets', view_mode: 'kanban',
      table_columns: %w[number title], header_columns: %w[assignees],
      list_columns: { 'cells' => [], 'metadata' => [] }
    )
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: {
                                           'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ]
                                         })

    get organisation_project_tickets_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect(page).to have_css('div.layout.kanban-layout.two-column.layout--lane.hide-panel')
    children = page.all('div.layout.kanban-layout > *', visible: :all)
    expect(children.map { |child| [child.tag_name, child[:class]] }).to eq([
                                                                             ['aside', 'column list column-spacing-sm'],
                                                                             ['div', 'lane-split'],
                                                                             ['main', 'column content column-spacing-sm'],
                                                                             ['aside', 'column panel']
                                                                           ])
    expect(page).to have_css('#ticket_display_frame', count: 1, visible: :all)
    expect(page).to have_no_css('.kanban-slide-over', visible: :all)
    expect_closed_meeting_lane
  end

  # The knowledge page lost its panel on 10.09.2026 (S0 of
  # doc/wissen_als_bahn_plan.md): it held "Chat-Funktion in Entwicklung" since
  # the project chat went with #666, and the lane rules the page is about to
  # adopt are written for .hide-panel only. Pinned in the negative like the
  # ticket pages: no aside but the list, and no trigger that could toggle a
  # panel the grid does not have.
  it 'renders no panel lane on the knowledge index (the chat placeholder is gone)' do
    get organisation_project_knowledge_index_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect(page).to have_css('div.layout.two-column.hide-panel')
    expect(page).to have_css('div.layout.two-column > aside', count: 1)
    expect(page).to have_no_css('aside.column.panel', visible: :all)
    expect(page).to have_no_css('[data-action~="click->layout-toggle#togglePanel"]', visible: :all)
  end

  it 'renders no third panel lane on the meetings index' do
    get organisation_project_meetings_path(organisation, project)

    expect(response).to have_http_status(:ok)
    expect(page).to have_css('div.layout.two-column.hide-panel')
    expect(page).to have_css('div.layout.two-column > aside', count: 1)
    expect(page).to have_no_css('aside.column.panel', visible: :all)
    expect(page).to have_no_css('[data-action~="click->layout-toggle#togglePanel"]', visible: :all)
  end
end
