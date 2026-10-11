# frozen_string_literal: true

require 'rails_helper'

# What: the selection column of the ticket list (doc/ticket_bulk_edit_plan.md, slice 1).
# Type: request spec against the index.
# Why: the box is the first cell of head and rows, inside a no-click cell so the
#   row click still opens the ticket, and only for readers who may write tickets.
#   A read-only reader must see no box, no head box and the narrower fixed width
#   the fit script subtracts. The board renders no rows, so no boxes there.
RSpec.describe 'Ticket list selection column', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:tickets) do
    ActsAsTenant.with_tenant(organisation) do
      create_list(:ticket, 2, project: project, organisation: organisation, creator: user)
    end
  end
  let(:tickets_path) { organisation_project_tickets_path(organisation, project) }
  let(:fixed_without_box) { ViewConfiguration::COLUMN_MIN_WIDTH_PX['number'] + ViewConfiguration::COLUMN_MIN_WIDTH_PX['title'] }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def document
    Nokogiri::HTML(response.body)
  end

  def fixed_width
    document.at_css('#ticket-index-container')['data-column-picker-fixed-width-value'].to_i
  end

  context 'as a writer' do
    before do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      sign_in user
      get tickets_path
    end

    it 'renders the head box as the first head cell' do
      expect(response).to have_http_status(:ok)
      first_head = document.at_css('thead tr th')
      expect(first_head['data-column']).to eq('select')
      head_box = first_head.at_css('input.ticket-select-box--head')
      expect(head_box['data-ticket-selection-target']).to eq('headBox')
      expect(head_box['data-action']).to eq('click->ticket-selection#togglePage')
    end

    it 'renders one box per row, inside a no-click cell, carrying the ticket id' do
      cells = document.css('tr[data-ticket-id] td[data-column="select"]')
      expect(cells.size).to eq(2)
      expect(cells.map { |cell| cell['class'] }).to all(include('no-click'))
      boxes = cells.map { |cell| cell.at_css('input.ticket-select-box') }
      expect(boxes.map { |box| box['value'] }).to match_array(tickets.map(&:id))
      expect(boxes.map { |box| box['data-action'] }).to all(eq('click->ticket-selection#toggle'))
      expect(boxes.map { |box| box['data-ticket-selection-target'] }).to all(eq('box'))
    end

    it 'mounts the selection controller around head and frame, with the selection row in the bar' do
      mount = document.at_css('[data-controller~="ticket-selection"]')
      expect(mount).to be_present
      expect(mount['data-ticket-selection-frame-value']).to eq('tickets_list_frame')
      expect(mount['data-ticket-selection-count-other-value']).to match(/%\{count\}/)
      expect(mount.at_css('turbo-frame#tickets_list_frame')).to be_present
      expect(mount.at_css('[data-ticket-selection-target="row"]')).to be_present
      expect(mount.at_css('[data-ticket-selection-target="count"]')).to be_present
      expect(mount.at_css('button[data-action="click->ticket-selection#clear"]')).to be_present
      # Slice 2: the second step and its reason, hidden until the page is full;
      # the cap the server enforces is the one the row will show.
      all_step = mount.at_css('button[data-ticket-selection-target="all"]')
      expect(all_step.has_attribute?('hidden')).to be(true)
      expect(all_step['data-action']).to eq('click->ticket-selection#selectAll')
      expect(mount.at_css('[data-ticket-selection-target="allReason"]').has_attribute?('hidden')).to be(true)
      expect(mount['data-ticket-selection-max-value']).to eq(Tickets::BulkSelection::MAX_TICKETS.to_s)
      expect(mount['data-ticket-selection-select-all-label-value']).to match(/%\{count\}/)
      expect(mount['data-ticket-selection-too-many-value']).to match(/%\{max\}/)
      expect(mount['data-ticket-selection-count-all-other-value']).to match(/%\{count\}/)
      # Slice 3: the panel's address and the lane frame, and the two window
      # events the panel talks over.
      expect(mount['data-ticket-selection-panel-url-value']).to eq(bulk_edit_organisation_project_tickets_path(organisation, project))
      expect(mount['data-ticket-selection-display-frame-value']).to eq('ticket_display_frame')
      expect(mount['data-action']).to include('ticket-bulk-panel:ready@window->ticket-selection#announce')
      expect(mount['data-action']).to include('ticket-bulk-panel:close@window->ticket-selection#closePanel')
      # The row stands right after the sentence frame: the two share one place.
      sentence = mount.at_css('turbo-frame#tickets_list_frame_sentence')
      expect(sentence).to be_present
      expect(sentence.next_element['data-ticket-selection-target']).to eq('row')
    end

    it 'hands the fit script the box width beside number and title' do
      expect(fixed_width).to eq(fixed_without_box + ViewConfiguration::SELECT_COLUMN_WIDTH_PX)
    end
  end

  context 'as a reader (tickets read_only)' do
    before do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
      sign_in user
      get tickets_path
    end

    it 'renders the rows without any box and keeps the fixed width at number plus title' do
      expect(response).to have_http_status(:ok)
      expect(document.css('tr[data-ticket-id]').size).to eq(2)
      expect(document.css('input.ticket-select-box')).to be_empty
      expect(document.css('[data-column="select"]')).to be_empty
      expect(fixed_width).to eq(fixed_without_box)
    end
  end

  context 'on the board' do
    let!(:status_attr) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                                             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
                                           ] })
    end

    before do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      ViewConfiguration.create!(user: user, project: project, organisation: organisation,
                                view_type: 'tickets', view_mode: 'kanban',
                                table_columns: %w[number title], header_columns: %w[assignees],
                                list_columns: { 'cells' => [], 'metadata' => [] })
      sign_in user
      get tickets_path
    end

    it 'renders no box at all' do
      expect(response).to have_http_status(:ok)
      expect(document.css('input.ticket-select-box')).to be_empty
      expect(document.at_css('[data-controller~="ticket-selection"]')).to be_nil
    end
  end
end
