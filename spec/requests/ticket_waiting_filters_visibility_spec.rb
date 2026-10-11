# frozen_string_literal: true

require 'rails_helper'

# The two waiting filters on a ticket list (doc/ticket_relations_plan.md, revision 4, §4, §9).
#
# 1. A filter only narrows. Whether a ticket waits counts every blocker, readable or not (the
#    state is a fact about THIS ticket), but the answer is always a subset of the list the reader
#    sees anyway: a list of one project never shows a ticket of another.
# 2. Nothing about the other end leaves the server: no title, number or project of a ticket the
#    reader cannot open, neither through "Wartet" nor through "Hält auf".
#
# Every negative claim stands next to a positive one in the same response: the filtered ticket is
# in the body, so "not in the body" is not green on an error page.
RSpec.describe 'Ticket waiting filters: a narrower list, nothing about other tickets', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project('Kundenportal') }
  let(:readable_project) { new_project('Backoffice') }
  let(:hidden_project) { new_project('Vorstand') }
  let(:user) { member(tickets: { project => 'read_write', readable_project => 'read_only' }) }

  before do
    [project, readable_project, hidden_project].each { |each_project| status_field(each_project) }
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets', view_mode: 'table',
                                table_columns: %w[number title waiting], list_columns: { 'cells' => [], 'metadata' => [] },
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

  def link(source, target, type = :blocks)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type)
      end
    end
  end

  def row_ids(body)
    Nokogiri::HTML(body).css('tr[data-ticket-id]').map { |row| row['data-ticket-id'] }
  end

  def list(filter, filter_op = {})
    get organisation_project_tickets_path(organisation, project), params: { filter: filter, filter_op: filter_op }
    expect(response).to have_http_status(:ok)
    response.body
  end

  # Numbers no other ticket here carries, so their absence from a response means something.
  let!(:waiter) { ticket(project, 'Checkout breaks') }
  let!(:hidden_blocker) { ticket(hidden_project, 'Board decision on budget', number: 4711) }
  let!(:holder) { ticket(project, 'Payment provider contract') }
  let!(:hidden_waiter) { ticket(hidden_project, 'Supervisory board minutes', number: 4712) }
  # Waits too, on a ticket of the list, but lives in a project the reader can read: still not
  # part of THIS list.
  let!(:readable_waiter) { ticket(readable_project, 'Backoffice import', number: 4713) }
  let!(:plain) { ticket(project, 'Footer link') }

  let(:hidden_secrets) do
    ['Board decision on budget', 'Supervisory board minutes', 'Vorstand',
     hidden_blocker.id, hidden_waiter.id, 4711, 4712]
  end

  before do
    link(hidden_blocker, waiter)
    link(holder, hidden_waiter, :precedes)
    link(holder, readable_waiter)
  end

  describe 'Wartet' do
    it "'ist' keeps the ticket that waits on a blocker the reader cannot open, and names nothing of it" do
      body = list({ waiting: ['true'] })

      expect(row_ids(body)).to eq([waiter.id])
      expect(body).to include('Checkout breaks')
      expect_absent(body, *hidden_secrets, 'Backoffice import', 4713)
    end

    it "'ist nicht' keeps the rest of this project's list, and nothing from elsewhere" do
      body = list({ waiting: ['true'] }, { waiting: 'not' })

      expect(row_ids(body)).to contain_exactly(holder.id, plain.id)
      expect(body).to include('Payment provider contract')
      expect_absent(body, *hidden_secrets, 'Backoffice import', 4713)
    end
  end

  describe 'Hält auf' do
    it "'ist' keeps the ticket that holds up a ticket the reader cannot open, and names nothing of it" do
      body = list({ blocking: ['true'] })

      expect(row_ids(body)).to eq([holder.id])
      expect(body).to include('Payment provider contract')
      expect_absent(body, *hidden_secrets, 'Backoffice import', 4713)
    end

    it 'counts a hidden waiter alone: the state does not depend on what the reader may see' do
      ActsAsTenant.with_tenant(organisation) do
        TicketRelation.where(source_ticket: holder, target_ticket: readable_waiter).delete_all
      end

      body = list({ blocking: ['true'] })

      expect(row_ids(body)).to eq([holder.id])
      expect_absent(body, *hidden_secrets)
    end
  end

  it 'narrows a saved view the same way' do
    folder = ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, organisation: organisation, user: user, project: nil, target_object_type: 'Ticket').tap do |view|
        view.smart_folder_rule_groups.create!(position: 1)
            .smart_folder_rules.create!(field: 'waiting', operator: SmartFolders::Operators::IS, value: 'true', position: 1)
      end
    end

    get organisation_project_tickets_path(organisation, project, smart_folder_id: folder.id)

    expect(response).to have_http_status(:ok)
    expect(row_ids(response.body)).to eq([waiter.id])
    expect(response.body).to include('Checkout breaks')
    expect_absent(response.body, *hidden_secrets, 'Backoffice import', 4713)
  end
end
