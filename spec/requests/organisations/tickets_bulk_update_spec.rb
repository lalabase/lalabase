# frozen_string_literal: true

require 'rails_helper'

# What: PATCH tickets/bulk_update and PATCH tickets/bulk_runs/:id/undo
#   (doc/ticket_bulk_edit_plan.md, slice 6).
# Type: request spec.
# Why: the panel sends JSON (selection, changes, stock) with the list's address
#   in the query; the answer is a Turbo stream that re-renders the list frame
#   and writes the result line with the changed ids and "Rückgängig"; a refused
#   run answers 422 with its reason and nothing written; a reader is turned
#   away; the undo restores and marks the run.
RSpec.describe 'Ticket bulk update', :bulk_edit, type: :request do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let!(:tickets) { [bulk_ticket(title: 'Bug one'), bulk_ticket(title: 'Bug two'), bulk_ticket(title: 'Plain')] }
  let(:update_path) { bulk_update_organisation_project_tickets_path(organisation, project) }
  let(:json_headers) { { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'text/vnd.turbo-stream.html' } }

  before { bulk_project_setup }
  after { ActsAsTenant.current_tenant = nil }

  def document
    Nokogiri::HTML(response.body)
  end

  # The request cycle resets the tenant on this thread; the runs are read
  # under it again.
  def runs
    ActsAsTenant.with_tenant(organisation) { TicketBulkRun.all.to_a }
  end

  # The result line reads the run through the catalogue of the reader; a tag
  # the run took off its last tickets is no longer in that catalogue for a
  # member, and the line must still name it (review of #926).
  context 'as a member who removes a tag from its last tickets' do
    let(:member) { create(:user) }

    before do
      create(:membership, user: member, organisation: organisation, active: true,
                          role: create(:role, organisation: organisation, title: 'Member', is_default: true))
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
      tickets.first(2).each { |ticket| ticket.tag_list = ['einzeln'] }
      sign_in member
    end

    it 'names the removed tag in the result line' do
      patch update_path,
            params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) },
                      changes: [{ field: 'tags', remove: ['einzeln'] }] }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(document.at_css('[data-run-ticket-ids]').text).to include('−einzeln')
    end
  end

  context 'as a writer' do
    before { sign_in writer }

    it 'changes the ticked tickets, re-renders the list and writes the result line with the ids and the undo' do
      patch update_path,
            params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) },
                      changes: [{ field: 'status', value: 'wip' }] }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(tickets.first(2).map { |t| t.reload.custom_attributes['status'] }).to all(eq('wip'))
      expect(tickets.last.reload.custom_attributes['status']).to eq('open')

      streams = document.css('turbo-stream')
      expect(streams.map { |s| [s['action'], s['target']] }).to include(%w[update tickets_list_frame], %w[update ticket-selection-result])
      line = document.at_css('[data-run-ticket-ids]')
      expect(line['data-run-ticket-ids'].split(',')).to match_array(tickets.first(2).map(&:id))
      expect(line.text).to include('in Arbeit').and include('2 Tickets geändert')
      run = runs.last
      expect(line.at_css("form[action='#{undo_bulk_run_organisation_project_tickets_path(organisation, project, id: run.id)}']")).to be_present
    end

    it 'changes every hit of the address in mode all' do
      patch "#{update_path}?search=Bug&search_mode=title_only",
            params: { selection: { mode: 'all', expected_count: 2 }, changes: [{ field: 'status', value: 'wip' }] }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(tickets.first(2).map { |t| t.reload.custom_attributes['status'] }).to all(eq('wip'))
      expect(tickets.last.reload.custom_attributes['status']).to eq('open')
    end

    it 'refuses a stale stock with its reason and writes nothing' do
      stale = Tickets::BulkSummary.call(project: project, ticket_ids: tickets.map(&:id),
                                        fields: Tickets::BulkFields.for(project: project, user: writer))[:fields]['status'][:digest]
      tickets.first.update!(custom_attributes: { 'status' => 'wip' })

      patch update_path,
            params: { selection: { mode: 'ids', ids: tickets.map(&:id) }, changes: [{ field: 'status', value: 'open' }],
                      stock: { status: stale } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css('turbo-stream[target="ticket-selection-result"]').text).to include('Bestand')
      expect(runs).to be_empty
    end

    it 'tags the ticked tickets with a name nobody has made yet, and the undo takes it off again' do
      patch update_path,
            params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) },
                      changes: [{ field: 'tags', add: ['Kunde-X'] }] }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      tag = ActsAsTenant.with_tenant(organisation) { Tag.find_by(name: 'kunde-x') }
      expect(tag.organisation_id).to eq(organisation.id)
      expect(tickets.first(2).map { |t| t.reload.tag_list }).to all(eq(['kunde-x']))
      expect(tickets.last.reload.tag_list).to be_empty
      expect(document.at_css('[data-run-ticket-ids]').text).to include('+kunde-x')

      patch undo_bulk_run_organisation_project_tickets_path(organisation, project, id: runs.last.id), headers: json_headers
      expect(response).to have_http_status(:ok)
      expect(tickets.first(2).map { |t| t.reload.tag_list }).to all(be_empty)
    end

    it 'refuses a new tag name over the limit with the limit in words, and writes nothing' do
      patch update_path,
            params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) },
                      changes: [{ field: 'tags', add: ['x' * (Tag::MAX_NAME_LENGTH + 1)] }] }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css('turbo-stream[target="ticket-selection-result"]').text).to include("#{Tag::MAX_NAME_LENGTH} Zeichen")
      expect(runs).to be_empty
      expect(ActsAsTenant.with_tenant(organisation) { Tag.where('length(name) > ?', Tag::MAX_NAME_LENGTH) }).to be_empty
    end

    it 'refuses a stale count in mode all and an empty change' do
      patch "#{update_path}?search=Bug&search_mode=title_only",
            params: { selection: { mode: 'all', expected_count: 9 }, changes: [{ field: 'status', value: 'wip' }] }.to_json,
            headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(document.text).to include('Liste hat sich')

      patch update_path, params: { selection: { mode: 'ids', ids: [tickets.first.id] }, changes: [] }.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(runs).to be_empty
    end

    it 'takes a run back through the undo route' do
      patch update_path,
            params: { selection: { mode: 'ids', ids: tickets.first(2).map(&:id) }, changes: [{ field: 'status', value: 'wip' }] }.to_json,
            headers: json_headers
      run = runs.last

      patch undo_bulk_run_organisation_project_tickets_path(organisation, project, id: run.id),
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(tickets.first(2).map { |t| t.reload.custom_attributes['status'] }).to all(eq('open'))
      expect(ActsAsTenant.with_tenant(organisation) { run.reload }).to be_undone
      expect(document.at_css('[data-run-ticket-ids]').text).to include('Zurückgenommen')
      expect(document.at_css('[data-run-ticket-ids] form')).to be_nil, 'an undo has no undo'
    end
  end

  context 'as a reader (tickets read_only)' do
    let(:reader) { create(:user) }

    before do
      create(:membership, user: reader, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: reader, project: project, tickets_access: 'read_only')
      sign_in reader
    end

    it 'is turned away and nothing is written' do
      patch update_path,
            params: { selection: { mode: 'ids', ids: [tickets.first.id] }, changes: [{ field: 'status', value: 'wip' }] }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:redirect)
      expect(tickets.first.reload.custom_attributes['status']).to eq('open')
      expect(runs).to be_empty
    end
  end
end
