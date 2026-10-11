# frozen_string_literal: true

require 'rails_helper'

# What: the other actions of the bulk panel (doc/ticket_bulk_edit_plan.md, slice 7):
#   POST tickets/bulk_impact, POST tickets/bulk_move, DELETE tickets/bulk_destroy.
# Type: request spec.
# Why: the dialogs name numbers from the live selection; a move and a delete
#   answer like a run (the list re-rendered, the result line without ids and
#   without an undo); a missing target is a named refusal; the rows and the
#   actions are gated by the move and delete rights, not by the write right.
RSpec.describe 'Ticket bulk actions', :bulk_edit, type: :request do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:target) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Ziel') } }
  let!(:tickets) { [bulk_ticket(title: 'Bug one'), bulk_ticket(title: 'Bug two'), bulk_ticket(title: 'Plain')] }
  let(:impact_path) { bulk_impact_organisation_project_tickets_path(organisation, project, format: :json) }
  let(:move_path) { bulk_move_organisation_project_tickets_path(organisation, project) }
  let(:destroy_path) { bulk_destroy_organisation_project_tickets_path(organisation, project) }
  let(:stream_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'text/vnd.turbo-stream.html' } }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' } }

  before { bulk_project_setup }
  after { ActsAsTenant.current_tenant = nil }

  def document
    Nokogiri::HTML(response.body)
  end

  def in_tenant(&)
    ActsAsTenant.with_tenant(organisation, &)
  end

  context 'as an admin' do
    before { sign_in writer }

    it 'counts what a delete and a move take with them' do
      in_tenant { create(:post, ticket: tickets.first, user: writer, organisation: organisation) }

      post impact_path, params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) } }.to_json, headers: json_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('count' => 2, 'posts' => 1, 'documents' => 0, 'time_sessions' => 0, 'children' => 0, 'hierarchy' => 0)

      post impact_path, params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) }, target_project_id: target.id }.to_json,
                        headers: json_headers
      expect(response.parsed_body['move']).to eq('lost_assignments' => 0, 'lost_subscriptions' => 0)
    end

    it 'moves the ticked tickets, re-renders the list and writes the result line without ids or undo' do
      post move_path, params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) }, target_project_id: target.id }.to_json,
                      headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(in_tenant { tickets.first(2).map { |t| t.reload.project_id } }).to all(eq(target.id))
      expect(in_tenant { tickets.last.reload.project_id }).to eq(project.id)
      streams = document.css('turbo-stream')
      expect(streams.map { |s| [s['action'], s['target']] }).to include(%w[update tickets_list_frame], %w[update ticket-selection-result])
      line = document.at_css('[data-run-kind="move"]')
      expect(line['data-run-ticket-ids']).to eq('')
      expect(line.text).to include('2 Tickets nach „Ziel“ verschoben')
      expect(line.at_css('form')).to be_nil
      expect(line.at_css('[data-action="click->ticket-selection#dismissResult"]')).to be_present
    end

    it 'refuses a move without a target and writes nothing' do
      post move_path, params: { selection: { mode: 'ids', ids: [tickets.first.id] } }.to_json, headers: stream_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css('[role="alert"]').text).to include('Zielprojekt')
      expect(in_tenant { tickets.first.reload.project_id }).to eq(project.id)
      expect(in_tenant { TicketBulkRun.count }).to eq(0)
    end

    it 'deletes the ticked tickets and writes the result line' do
      ids = [tickets.first.id, tickets.last.id]

      delete destroy_path, params: { selection: { mode: 'ids', ids: ids } }.to_json, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(in_tenant { Ticket.where(id: ids).exists? }).to be(false)
      expect(in_tenant { Ticket.exists?(tickets[1].id) }).to be(true)
      line = document.at_css('[data-run-kind="delete"]')
      expect(line.text).to include('2 Tickets gelöscht')
      expect(line.at_css('form')).to be_nil
    end
  end

  context 'as a writer without the move and delete rights' do
    let(:member) { create(:user) }

    before do
      create(:membership, user: member, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
      sign_in member
    end

    it 'gets the panel without the two rows and is turned away from both actions' do
      get bulk_edit_organisation_project_tickets_path(organisation, project), headers: { 'Turbo-Frame' => 'ticket_display_frame' }
      expect(response).to have_http_status(:ok)
      expect(document.at_css('[data-action="click->ticket-bulk-panel#openMove"]')).to be_nil
      expect(document.at_css('[data-action="click->ticket-bulk-panel#openDelete"]')).to be_nil

      post move_path, params: { selection: { mode: 'ids', ids: [tickets.first.id] }, target_project_id: target.id }.to_json,
                      headers: stream_headers
      expect(response).not_to have_http_status(:ok)
      expect(in_tenant { tickets.first.reload.project_id }).to eq(project.id)

      delete destroy_path, params: { selection: { mode: 'ids', ids: [tickets.first.id] } }.to_json, headers: stream_headers
      expect(response).not_to have_http_status(:ok)
      expect(in_tenant { Ticket.exists?(tickets.first.id) }).to be(true)
      expect(in_tenant { TicketBulkRun.count }).to eq(0)
    end
  end
end
