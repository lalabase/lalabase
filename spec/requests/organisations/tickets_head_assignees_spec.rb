# frozen_string_literal: true

require 'rails_helper'

# The people menu in the ticket head (user, 09.09.2026): a writer sets the
# assignees where the status and the priority are set, without the edit form.
# The menu sends the difference to what it showed as ONE add/remove change of
# the registry (Tickets::Changes, field assignees) to the endpoint the status
# uses; the response streams the head, scoped to THIS ticket, the list row and
# the board card.
RSpec.describe 'Ticket head assignees', type: :request do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user, first_name: 'Willi', last_name: 'Writer') }
  let(:colleague) { create(:user, first_name: 'Anna', last_name: 'Berg') }
  let(:reader) { create(:user, first_name: 'Rita', last_name: 'Reader') }
  let(:outsider) { create(:user, first_name: 'Otto', last_name: 'Out') }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let(:plain_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: writer) } }
  let(:endpoint) { update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket) }
  let(:stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: writer, organisation: organisation, role: admin_role)
    create(:membership, user: colleague, organisation: organisation, role: admin_role)
    # A reader: a plain role, and read access to this project's tickets alone.
    create(:membership, user: reader, organisation: organisation, role: plain_role)
    create(:project_permission, user: reader, project: project, tickets_access: 'read_only')
    # An outsider: in the organisation, without a way into this project.
    create(:membership, user: outsider, organisation: organisation, role: plain_role)
  end

  def assignees_of(ticket)
    ActsAsTenant.with_tenant(organisation) { ticket.reload.assignees.to_a }
  end

  describe 'PATCH update_kanban_attribute with add and remove' do
    before { sign_in writer }

    it 'adds a person and streams the head of this ticket, the row and the card' do
      patch endpoint, params: { attribute_name: 'assignees', add: [colleague.id] }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(assignees_of(ticket)).to contain_exactly(colleague)
      streams = Nokogiri::HTML.fragment(response.body).css('turbo-stream')
      targets = streams.map { |stream| stream['targets'] || stream['target'] }
      expect(targets).to include("#ticket_display_frame [data-ticket-id='#{ticket.id}'] #ticket-header",
                                 # Desktop and mobile row, each from its own partial
                                 # (TicketListColumns#ticket_list_row_streams).
                                 "tr[data-ticket-id='#{ticket.id}']",
                                 ".mobile-ticket-row[data-ticket-id='#{ticket.id}']",
                                 "kanban-card-#{ticket.id}")
      # The head that comes back already shows the person, ticked in the menu.
      head = streams.find { |stream| stream['targets'].to_s.start_with?('#ticket_display_frame ') }
      option = head.at_css(%(input[data-inline-assignees-target="option"][value="#{colleague.id}"]))
      expect(option.has_attribute?('checked')).to be(true)
    end

    it 'removes a person and adds another in one change' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << colleague }

      patch endpoint, params: { attribute_name: 'assignees', add: [writer.id], remove: [colleague.id] },
                      headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(assignees_of(ticket)).to contain_exactly(writer)
    end

    it 'refuses a person who is not in the project, before the ticket is touched' do
      patch endpoint, params: { attribute_name: 'assignees', add: [outsider.id] }, headers: stream_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('value_not_allowed')
      expect(assignees_of(ticket)).to be_empty
    end

    # A person assigned while they had access, who lost it since: the write is
    # refused as a whole, and the board says why instead of "could not be saved".
    # A person who stays assigned is not a new request: a stale assignee (no
    # access any more) stays on the ticket while somebody else is added.
    it 'adds a person beside a stale assignee, who stays' do
      ActsAsTenant.with_tenant(organisation) { ticket.ticket_assignments.create!(user: outsider) }

      patch endpoint, params: { attribute_name: 'assignees', add: [writer.id] }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(assignees_of(ticket)).to contain_exactly(outsider, writer)
    end

    it 'adds a person beside a deactivated assignee, who stays' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << colleague }
      Membership.find_by!(user: colleague, organisation: organisation).update!(active: false)

      patch endpoint, params: { attribute_name: 'assignees', add: [writer.id] }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(assignees_of(ticket)).to contain_exactly(colleague, writer)
    end

    # The person added lost access between the menu and the write (the
    # option list was read before): the board says why.
    it 'names a person who lost access in the meantime as the reason, changing nothing' do
      allow_any_instance_of(Ticket).to receive(:assignable_user_ids).and_return([])

      patch endpoint, params: { attribute_name: 'assignees', add: [writer.id] }, headers: stream_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        'code' => 'user_not_assignable',
        'error' => 'Eine Person hat inzwischen keinen Zugang mehr zu diesem Projekt. Nichts wurde geändert.'
      )
      expect(assignees_of(ticket)).to be_empty
    end

    # The menu shows the person ticked (assignable_users_for keeps whoever is
    # assigned), so unticking them must be accepted, also without a membership.
    it 'removes an assignee whose membership was deleted, together with another tick' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << colleague }
      Membership.find_by!(user: colleague, organisation: organisation).destroy!

      patch endpoint, params: { attribute_name: 'assignees', add: [writer.id], remove: [colleague.id] },
                      headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(assignees_of(ticket)).to contain_exactly(writer)
    end

    it 'refuses a deactivated member, as the edit form does' do
      Membership.find_by!(user: colleague, organisation: organisation).update!(active: false)

      patch endpoint, params: { attribute_name: 'assignees', add: [colleague.id] }, headers: stream_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('value_not_allowed')
      expect(assignees_of(ticket)).to be_empty
    end

    # The menu shows the stale person ticked (see 'the head'), so unticking
    # them must be accepted: a person once assigned is removable.
    it 'removes a stale assignee and adds another in one change' do
      ActsAsTenant.with_tenant(organisation) { ticket.ticket_assignments.create!(user: outsider) }

      patch endpoint, params: { attribute_name: 'assignees', add: [writer.id], remove: [outsider.id] },
                      headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(assignees_of(ticket)).to contain_exactly(writer)
    end

    it 'refuses a change that names nobody' do
      patch endpoint, params: { attribute_name: 'assignees', add: [], remove: [] }, headers: stream_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('nothing_to_change')
    end
  end

  # The edit form sends the whole list, the deactivated person included (the
  # picker keeps whoever is assigned). Saving another field must not drop them.
  describe 'the edit form with a deactivated assignee' do
    before { sign_in writer }

    it 'keeps them when another field is saved' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << colleague }
      Membership.find_by!(user: colleague, organisation: organisation).update!(active: false)

      patch organisation_project_ticket_path(organisation, project, ticket),
            params: { ticket: { title: 'Neu', assignee_ids: ['', colleague.id] } }

      expect(response).to have_http_status(:redirect)
      expect(assignees_of(ticket)).to contain_exactly(colleague)
    end

    it 'does not add a deactivated member who was not assigned' do
      Membership.find_by!(user: colleague, organisation: organisation).update!(active: false)

      patch organisation_project_ticket_path(organisation, project, ticket),
            params: { ticket: { title: 'Neu', assignee_ids: ['', colleague.id] } }

      expect(assignees_of(ticket)).to be_empty
    end
  end

  describe 'PATCH update_kanban_attribute as a reader' do
    before { sign_in reader }

    it 'is refused and changes nothing' do
      patch endpoint, params: { attribute_name: 'assignees', add: [reader.id] }, headers: stream_headers

      expect(response).to have_http_status(:found)
      expect(assignees_of(ticket)).to be_empty
    end
  end

  describe 'the head' do
    def head_for(ticket)
      get organisation_project_tickets_path(organisation, project), params: { ticket_id: ticket.id }
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body).at_css('#ticket_display_frame #ticket-header')
    end

    it 'is a menu for a writer: everyone who may read the tickets, the viewer first, the assigned ticked' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << colleague }
      sign_in writer

      head = head_for(ticket)
      menu = head.at_css('[data-controller="inline-assignees"]')
      expect(menu).to be_present
      expect(menu.at_css('form')['action']).to eq(endpoint)
      expect(menu.at_css('button[data-inline-assignees-target="badge"]')['title']).to eq('Zuweisung ändern')

      options = menu.css('input[data-inline-assignees-target="option"]')
      expect(options.map { |option| option['value'] }).to eq([writer.id, colleague.id, reader.id])
      expect(options.map { |option| option.has_attribute?('checked') }).to eq([false, true, false])
      expect(options.map { |option| option['value'] }).not_to include(outsider.id)
      expect(menu.text).to include('Fertig')
    end

    it 'leaves a deactivated member out and keeps a stale assignee in, ticked' do
      Membership.find_by!(user: colleague, organisation: organisation).update!(active: false)
      ActsAsTenant.with_tenant(organisation) { ticket.ticket_assignments.create!(user: outsider) }
      sign_in writer

      options = head_for(ticket).css('input[data-inline-assignees-target="option"]')
      values = options.map { |option| option['value'] }
      expect(values).not_to include(colleague.id)
      expect(values).to include(writer.id, reader.id, outsider.id)
      expect(options.find { |option| option['value'] == outsider.id }.has_attribute?('checked')).to be(true)
    end

    it 'is a plain segment for a reader' do
      sign_in reader

      head = head_for(ticket)
      expect(head.at_css('[data-controller="inline-assignees"]')).to be_nil
      expect(head.text).to include('ohne Zuweisung')
    end

    it 'is nothing when the view hides the assignees' do
      sign_in writer
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.for_user_project(writer, project, 'tickets').update!(detail_settings: { 'assignee_display' => 'off' })
      end

      head = head_for(ticket)
      expect(head.at_css('[data-controller="inline-assignees"]')).to be_nil
      expect(head.text).not_to include('ohne Zuweisung')
    end
  end
end
