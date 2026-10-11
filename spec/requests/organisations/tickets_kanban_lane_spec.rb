# frozen_string_literal: true

require 'rails_helper'

# What: the board opens its ticket in the same lane the table has
#   (doc/kanban_ticket_als_bahn_plan.md, S1a to S4 and S8).
# Type: request spec, the server half. The squeeze, the reveal, the drags and
#   the breakpoints are held by the owner's own clicks (the plan's section 8).
# Why: written to be red without the feature. The card and the row mount ONE
#   controller and read ONE page-level index address; the address decides what
#   is open; show and index build the same board from one pipeline; a frame
#   request for the lane skips the list's work; "+ Ticket" asks for a reload
#   instead of building a board; the view switch redirects back.
RSpec.describe 'Tickets kanban lane', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  let!(:status_attr) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: { 'allowed_values' => [
                                           { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                                           { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
                                         ] })
  end
  let!(:ticket) do
    create(:ticket, project: project, creator: user, title: 'Bahn auf dem Board', custom_attributes: { 'status' => 'Neu' })
  end
  let!(:other) do
    create(:ticket, project: project, creator: user, title: 'Die andere Karte', custom_attributes: { 'status' => 'Erledigt' })
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def tickets_path(**params)
    organisation_project_tickets_path(organisation, project, **params)
  end

  def page
    Capybara.string(response.body)
  end

  def board!
    ViewConfiguration.create!(user: user, project: project, organisation: organisation,
                              view_type: 'tickets', view_mode: 'kanban',
                              table_columns: %w[number title], header_columns: %w[assignees],
                              list_columns: { 'cells' => [], 'metadata' => [] })
  end

  describe 'one controller on the card and on the row' do
    # Click and Enter, NOT Space: on the board Space carries the card
    # (kanban_board_controller, doc/kanban_keyboard_plan.md D1, #765); the
    # table row below keeps its Space.
    it 'mounts list-row on the card, with click and Enter, the url and the id, and nothing of the old opener' do
      board!
      get tickets_path

      card = page.find("#kanban-card-#{ticket.id}")
      expect(card['data-controller']).to eq('list-row')
      expect(card['data-action']).to eq('click->list-row#click keydown.enter->list-row#click')
      expect(card['data-list-row-url-value']).to eq(organisation_project_ticket_path(organisation, project, ticket))
      expect(card['data-list-row-id-value']).to eq(ticket.id)
      expect(page).to have_no_css('[data-action*="kanban-board#openTicket"]')
      expect(page.find('#ticket-index-container')['data-index-url']).to eq(tickets_path)
    end

    it 'mounts the same controller on the table row, under the same page-level index address' do
      get tickets_path

      row = page.find("tr[data-ticket-id='#{ticket.id}']")
      expect(row['data-controller']).to eq('list-row')
      expect(row['data-list-row-id-value']).to eq(ticket.id)
      expect(page.find('#ticket-index-container')['data-index-url']).to eq(tickets_path)
    end
  end

  describe 'the address decides what is open' do
    before { board! }

    it 'renders the board with the lane open, the ticket in it and only its card toned' do
      get tickets_path(ticket_id: ticket.id)

      expect(response).to have_http_status(:ok)
      expect(page).to have_css('div.layout.kanban-layout.layout--lane.show-content')
      expect(page).to have_css("#ticket_display_frame [data-ticket-id='#{ticket.id}']")
      expect(page).to have_css('#ticket_display_frame', text: 'Bahn auf dem Board')
      expect(page).to have_css("#kanban-card-#{ticket.id}.selected-row")
      expect(page).to have_css('.kanban-card.selected-row', count: 1)
    end

    it 'renders the board with the lane shut and the placeholder without a ticket' do
      get tickets_path

      expect(page).to have_css('div.layout.kanban-layout.layout--lane.hide-content')
      expect(page).to have_css('#ticket_display_frame #ticket-display.ticket-placeholder')
      expect(page).to have_no_css('.kanban-card.selected-row')
    end

    it 'renders the board and the lane on the show route too, not the table' do
      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(page).to have_css('div.layout.kanban-layout [data-controller="kanban-board"]')
      expect(page).to have_no_css('#tickets_list_frame table')
      expect(page).to have_css("#kanban-card-#{ticket.id}.selected-row")
      expect(page).to have_css('#ticket_display_frame', text: 'Bahn auf dem Board')
    end

    it 'shows the same cards on index and show under the same search' do
      create(:ticket, project: project, creator: user, title: 'Bahn Nummer zwei', custom_attributes: { 'status' => 'Neu' })
      search = { search: 'Bahn', search_mode: 'title_only' }

      get tickets_path(**search)
      index_cards = page.all('.kanban-card').map { |card| card['data-ticket-id'] }.sort
      get organisation_project_ticket_path(organisation, project, ticket, **search)
      show_cards = page.all('.kanban-card').map { |card| card['data-ticket-id'] }.sort

      expect(index_cards.size).to eq(2)
      expect(show_cards).to eq(index_cards)
    end
  end

  describe 'the frame fast path' do
    # The list's callbacks are the part an early return would miss: set_objects
    # runs TicketSearchQuery from a before_action, before the action starts.
    it 'answers a ticket_display_frame request on the board with the lane alone, running neither the query nor the presenter' do
      board!
      expect(TicketSearchQuery).not_to receive(:new)
      expect(KanbanBoardPresenter).not_to receive(:new)

      get organisation_project_ticket_path(organisation, project, ticket, frame: 'content', search: 'x', search_mode: 'content'),
          headers: { 'Turbo-Frame' => 'ticket_display_frame' }

      expect(response).to have_http_status(:ok)
      expect(page).to have_css('turbo-frame#ticket_display_frame', text: 'Bahn auf dem Board')
      expect(page).to have_no_css('.kanban-board')
      expect(page).to have_no_css('[data-controller~="filter-bar"]')
    end

    it 'gives the table the same shortcut' do
      expect(TicketSearchQuery).not_to receive(:new)

      get organisation_project_ticket_path(organisation, project, ticket, frame: 'content', search: 'x', search_mode: 'content'),
          headers: { 'Turbo-Frame' => 'ticket_display_frame' }

      expect(response).to have_http_status(:ok)
      expect(page).to have_css('turbo-frame#ticket_display_frame', text: 'Bahn auf dem Board')
      expect(page).to have_no_css('table')
    end
  end

  describe '"+ Ticket" from a column' do
    before { board! }

    it 'answers the surface form with the reload action and no board' do
      post tickets_path, params: { source: 'kanban', ticket: { title: 'Frisch vom Board', custom_attributes: { status: 'Neu' } } },
                         headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      streams = Nokogiri::HTML.fragment(response.body).css('turbo-stream').map { |s| [s['action'], s['target']] }
      expect(streams).to include(%w[update writing_surface], %w[reloadFrame tickets_list_frame])
      expect(response.body).not_to include('kanban-board')
      ActsAsTenant.with_tenant(organisation) { expect(Ticket.find_by(title: 'Frisch vom Board')).to be_present }
    end

    # The frame GET with the page's address: its filters, and a ticket_id
    # beyond the column cap. The new card is there, and so is the open one,
    # appended past the cap with nothing counted as hidden.
    it 'renders the new card and the open one on the frame request with the page address' do
      stub_const('KanbanBoardPresenter::TICKETS_PER_COLUMN', 1)
      fresh = create(:ticket, project: project, creator: user, title: 'Frisch vom Board', custom_attributes: { 'status' => 'Neu' })

      get tickets_path(ticket_id: ticket.id, filter: { status: ['Neu'] }), headers: { 'Turbo-Frame' => 'tickets_list_frame' }

      expect(response).to have_http_status(:ok)
      expect(page).to have_css('turbo-frame#tickets_list_frame [data-controller="kanban-board"]')
      expect(page).to have_css("#kanban-card-#{fresh.id}")
      expect(page).to have_css("#kanban-card-#{ticket.id}.selected-row")
      expect(page).to have_no_css("#kanban-card-#{other.id}")
      expect(page).to have_no_text(I18n.t('kanban.more_tickets', count: 1))
    end
  end

  describe 'the view switch keeps the ticket' do
    let(:switch_path) { update_view_mode_organisation_project_view_configuration_path(organisation, project) }

    it 'redirects back to the referer with the ticket and the filters' do
      referer = tickets_path(ticket_id: ticket.id, filter: { status: ['Neu'] })
      patch switch_path, params: { view_mode: 'table' }, headers: { 'Referer' => "http://www.example.com#{referer}" }
      expect(response).to redirect_to(referer)
    end

    it 'redirects back to the referer without a ticket' do
      patch switch_path, params: { view_mode: 'kanban' }, headers: { 'Referer' => "http://www.example.com#{tickets_path}" }
      expect(response).to redirect_to(tickets_path)
    end

    # The other direction (user, 09.09.2026): the switch stands on the table
    # with a ticket open, and the change to the board keeps that ticket.
    it 'stands on the table with a ticket open, and the change to the board keeps the ticket' do
      get tickets_path(ticket_id: ticket.id)
      expect(page).to have_css('div.layout.show-content:not(.kanban-layout)')
      expect(page).to have_css('[data-page-view-switch]', visible: :all)

      referer = tickets_path(ticket_id: ticket.id)
      patch switch_path, params: { view_mode: 'kanban' }, headers: { 'Referer' => "http://www.example.com#{referer}" }
      expect(response).to redirect_to(referer)
    end

    it 'falls back to the index without a referer' do
      patch switch_path, params: { view_mode: 'kanban' }
      expect(response).to redirect_to(tickets_path)
    end
  end

  describe 'the markup of the board page' do
    it 'has no slide-over, no modal controller, no column picker trigger, and keeps the view switch' do
      board!
      get tickets_path

      expect(page).to have_no_css('.kanban-slide-over', visible: :all)
      expect(response.body).not_to include('kanban-ticket-modal')
      expect(page).to have_no_css('[data-column-picker-trigger]', visible: :all)
      expect(page).to have_css('[data-page-view-switch]', visible: :all)
      expect(page).to have_css(%(.kanban-nav [aria-label="#{I18n.t('kanban.scroll_left')}"]), visible: :all)
    end
  end
end
