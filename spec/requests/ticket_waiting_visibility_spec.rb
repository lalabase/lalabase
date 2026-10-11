# frozen_string_literal: true

require 'rails_helper'

# What leaves the server about OTHER tickets once the waiting state is in the list, on the
# board and on the phone (doc/ticket_relations_plan.md, revision 4, §4, §8.3, review 5).
#
# 1. The hourglass counts every open blocker, readable or not: the state is a fact about THIS
#    ticket. Cell, card, phone row and their labels say how many, never which: no title, number
#    or project of a blocker, least of all one the reader cannot open.
# 2. No stream for another ticket. Adding or removing a relation redraws the open ticket's own
#    row and card only; a status change of a blocker (edit form or board) redraws the blocker's
#    own row, never the row, card or hint of a ticket that waits on it. Such a stream would carry
#    that ticket's markup in the raw response, whether the browser finds a target or not.
#
# Negative claims stand next to a positive one in the same response: the own row or card is
# there, so "not in the body" is not green on an error page.
RSpec.describe 'Ticket waiting state: nothing about other tickets', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project('Kundenportal') }
  let(:readable_project) { new_project('Backoffice') }
  let(:hidden_project) { new_project('Vorstand') }
  let(:user) { member(tickets: { project => 'read_write', readable_project => 'read_only' }) }

  let(:table_columns) { %w[number title waiting] }
  let(:view_mode) { 'table' }

  let(:stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    [project, readable_project, hidden_project].each do |each_project|
      status_field(each_project)
    end
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets', view_mode: view_mode,
                                table_columns: table_columns, list_columns: { 'cells' => [], 'metadata' => [] },
                                header_columns: %w[assignees])
    end
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def new_project(name)
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: name) }
  end

  def status_field(project)
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition,
             project: project, name: 'status', field_type: 'select', system: true,
             options: { 'allowed_values' => [
               { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
               { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
             ] })
    end
  end

  def member(tickets:)
    person = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: person, organisation: organisation, role: role, active: true)
      tickets.each { |project, access| create(:project_permission, user: person, project: project, tickets_access: access) }
    end
    person
  end

  def ticket(in_project, title, **attributes)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: in_project, title: title, custom_attributes: { 'status' => 'Offen' }, **attributes)
      end
    end
  end

  def link(source, target)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: :blocks)
      end
    end
  end

  # Numbers no other ticket here carries, so their absence from a response means something.
  let(:waiter) { ticket(project, 'Checkout breaks') }
  let(:hidden_blocker) { ticket(hidden_project, 'Board decision on budget', number: 4711) }
  let(:hidden_secrets) { ['Board decision on budget', 'Vorstand', hidden_blocker.id, 4711] }

  def selectors_naming(ticket_id)
    [%(data-ticket-id='#{ticket_id}'), %(data-ticket-id="#{ticket_id}"), "kanban-card-#{ticket_id}",
     "ticket-relations-#{ticket_id}", "ticket-waiting-#{ticket_id}"]
  end

  def stream_targets(body)
    Nokogiri::HTML(body).css('turbo-stream').map { |node| node['target'] || node['targets'] }
  end

  describe 'the hourglass of a ticket that waits on a blocker the reader cannot open' do
    let(:label) { I18n.t('views.organisations.tickets.shared.relations.waiting_mark', count: 1) }

    before { link(hidden_blocker, waiter) }

    it 'counts it in the table and names nothing of it' do
      get organisation_project_tickets_path(organisation, project)

      cell = Nokogiri::HTML(response.body).at_css("tr[data-ticket-id='#{waiter.id}'] td[data-column='waiting']")
      expect(cell.text.strip).to eq('1')
      expect(cell.at_css('[role="img"]')['title']).to eq(label)
      expect_absent(response.body, *hidden_secrets)
    end

    it 'counts it on the phone and names nothing of it' do
      get organisation_project_tickets_path(organisation, project, viewport: 'mobile')

      mark = Nokogiri::HTML(response.body).at_css(".mobile-ticket-row[data-ticket-id='#{waiter.id}'] .ticket-waiting-mark")
      expect(mark['aria-label']).to eq(label)
      expect_absent(response.body, *hidden_secrets)
    end

    context 'on the board' do
      let(:view_mode) { 'kanban' }

      it 'counts it and names nothing of it' do
        get organisation_project_tickets_path(organisation, project)

        mark = Nokogiri::HTML(response.body).at_css("#kanban-card-#{waiter.id} .ticket-waiting-mark")
        expect(mark['title']).to eq(label)
        expect_absent(response.body, *hidden_secrets)
      end
    end
  end

  describe 'adding or removing a relation' do
    let(:other) { ticket(readable_project, 'Payment provider switch') }

    def own_row_present!(body)
      expect(stream_targets(body)).to include("tr[data-ticket-id='#{waiter.id}']", "kanban-card-#{waiter.id}")
    end

    it 'redraws only the open ticket: the other one is in the section, nowhere else' do
      post organisation_project_ticket_relations_path(organisation, project, waiter),
           params: { other_ticket_id: other.id, kind: 'blocked_by' }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      own_row_present!(response.body)
      expect(stream_targets(response.body).grep(/#{other.id}/)).to be_empty
      expect(response.body).not_to include(*selectors_naming(other.id))
    end

    it 'names the removed ticket nowhere at all' do
      link(other, waiter)
      relation = ActsAsTenant.without_tenant { TicketRelation.find_by!(source_ticket_id: other.id) }

      delete organisation_project_ticket_relation_path(organisation, project, waiter, relation), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      own_row_present!(response.body)
      expect(response.body).not_to include(other.id, 'Payment provider switch')
    end

    it 'names a blocker the reader cannot open nowhere, while counting it' do
      link(hidden_blocker, waiter)

      post organisation_project_ticket_relations_path(organisation, project, waiter),
           params: { other_ticket_id: other.id, kind: 'blocked_by' }, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      row = Nokogiri::HTML(response.body).css('turbo-stream')
                    .find { |node| node['targets'] == "tr[data-ticket-id='#{waiter.id}']" }
      expect(row.at_css("td[data-column='waiting']").text.strip).to eq('2')
      expect_absent(response.body, *hidden_secrets)
    end
  end

  # Plan §8.3 and §4: a blocker done does not reach the rows of the tickets that wait on it.
  # They show the hourglass until their list is loaded again.
  describe 'a blocker set to done while another ticket waits on it' do
    let(:blocker) { ticket(project, 'Release the API') }

    def done_by_edit_form
      patch organisation_project_ticket_path(organisation, project, blocker),
            params: { ticket: { title: blocker.title, custom_attributes: { status: 'Erledigt' } } },
            headers: stream_headers
    end

    def done_on_the_board
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, blocker),
            params: { attribute_name: 'status', value: 'Erledigt' }, headers: stream_headers
    end

    def expect_own_row_only(waiting)
      expect(response).to have_http_status(:ok)
      expect(stream_targets(response.body)).to include("tr[data-ticket-id='#{blocker.id}']")
      expect(stream_targets(response.body).compact.grep(/#{waiting.id}/)).to be_empty
      expect(response.body).not_to include(*selectors_naming(waiting.id))
    end

    context 'when the waiting ticket is in a project the reader cannot open' do
      let(:hidden_waiter) { ticket(hidden_project, 'Board salary review', number: 4712) }

      before { link(blocker, hidden_waiter) }

      it 'says nothing of it after the edit form' do
        done_by_edit_form

        expect_own_row_only(hidden_waiter)
        expect_absent(response.body, 'Board salary review', 'Vorstand', hidden_waiter.id, 4712)
      end

      it 'says nothing of it after a drop on the board' do
        done_on_the_board

        expect_own_row_only(hidden_waiter)
        expect_absent(response.body, 'Board salary review', 'Vorstand', hidden_waiter.id, 4712)
      end
    end

    context 'when the reader can open the waiting ticket' do
      let(:readable_waiter) { ticket(readable_project, 'Invoice run', number: 4713) }

      before { link(blocker, readable_waiter) }

      # The edit form answers with the whole display of the blocker, and its relations section
      # (PR 2) lists the ticket it holds up: readable, so shown there by right. That is the only
      # place: no row, card or hint of the waiting ticket.
      it 'sends no row, card or hint of it after the edit form, only the blocker section names it' do
        done_by_edit_form

        expect_own_row_only(readable_waiter)
        expect(response.body).to include('Invoice run')
        outside_section = Nokogiri::HTML(response.body).tap { |doc| doc.css('section[id^="ticket-relations-"]').each(&:remove) }
        expect(outside_section.to_html).not_to include('Invoice run', readable_waiter.id)
      end

      it 'says nothing of it after a drop on the board' do
        done_on_the_board

        expect_own_row_only(readable_waiter)
        expect_absent(response.body, 'Invoice run', readable_waiter.id, 4713)
      end
    end
  end
end
