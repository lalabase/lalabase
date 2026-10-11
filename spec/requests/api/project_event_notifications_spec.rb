# frozen_string_literal: true

require 'rails_helper'

# The token inbox returns a notification's payload as it is, and a project event keeps
# its parameters there: a moved ticket's title and number, the numbers and ids of a bulk
# run. Until 2026-10-08 a person who may read only documents in the project read both
# through GET /api/v1/notifications and list_notifications, because a project subject
# counted as "whole project". The rule now lives in Notification.readable (by the area of
# the event); this spec checks the whole answer, not a field.
#
# Numbers are matched as words: UUIDs and asset digests in a body contain four-digit runs.
RSpec.describe 'Token inbox: project events by the area of the event', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:source) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Quelle') } }
  let(:target) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Ziel') } }
  let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

  let(:title) { 'Umzugsplan-Zebra' }

  def member(areas)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: member_role, active: true)
      [source, target].each do |project|
        create(:project_permission, user: user, project: project, **areas.to_h { |area| [:"#{area}_access", 'read_only'] })
      end
    end
    user
  end

  def token_for(user)
    token = build(:personal_access_token, user: user, organisations: [organisation], read_only: true)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  def drain_outbox
    ActsAsTenant.without_tenant do
      OutboxEvent.where(processed_at: nil).order(:created_at).each { |event| Notifications::FanoutService.new(event).call }
    end
  end

  def mentions?(body, number) = body.match?(/(?<![0-9A-Za-z_-])#{number}(?![0-9A-Za-z_-])/)

  def rest_body(user)
    get '/api/v1/notifications', params: { status: 'all' }, headers: { 'Authorization' => "Bearer #{token_for(user).token}" }
    expect(response).to have_http_status(:ok)
    response.body
  end

  def mcp_body(user)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: 'list_notifications', arguments: { status: 'all' } } }.to_json,
                     headers: { 'Authorization' => "Bearer #{token_for(user).token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    response.body
  end

  def setup_writer
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: writer, organisation: organisation, active: true,
                          role: create(:admin_role, organisation: organisation))
    end
  end

  describe 'a ticket moved between projects' do
    let!(:docs_only) { member(%i[documents]) }
    let!(:ticket_reader) { member(%i[tickets]) }
    let(:moved_number) { 6281 }

    before do
      Prosopite.pause do
        setup_writer
        ActsAsTenant.with_tenant(organisation) do
          create(:ticket, project: target, organisation: organisation, creator: writer).update_columns(number: moved_number - 1)
          ticket = create(:ticket, project: source, organisation: organisation, creator: writer, title: title)
          ticket.update_columns(number: 9173)
          Current.user = writer
          Actors::MoveTicket.call(ticket: ticket.reload, target_project: target, current_user: writer)
        end
        Current.reset
        ActsAsTenant.current_tenant = nil
        drain_outbox
      end
    end

    it 'names the ticket to a reader of tickets (REST)' do
      body = rest_body(ticket_reader)
      expect(body).to include(title)
      expect(mentions?(body, moved_number)).to be true
    end

    it 'does not name it to a reader of documents alone (REST)' do
      body = rest_body(docs_only)
      expect(body).not_to include(title)
      expect(mentions?(body, moved_number)).to be false
      expect(mentions?(body, 9173)).to be false
    end

    it 'names the ticket to a reader of tickets (MCP)' do
      expect(mcp_body(ticket_reader)).to include(title)
    end

    it 'does not name it to a reader of documents alone (MCP)' do
      body = mcp_body(docs_only)
      expect(body).not_to include(title)
      expect(mentions?(body, moved_number)).to be false
    end
  end

  # Delivery of a bulk run already asks for the tickets area; what was open is the row
  # that stays after the right goes.
  describe 'a bulk run, after the person loses the tickets area' do
    include BulkEditHelpers

    let(:project) { source }
    let(:follower) { member(%i[tickets]) }
    let!(:tickets) { [bulk_ticket(title: 'Erster'), bulk_ticket(title: 'Zweiter')] }

    before do
      Prosopite.pause do
        bulk_project_setup
        ActsAsTenant.with_tenant(organisation) do
          tickets.zip([7705, 7706]).each { |ticket, number| ticket.update_columns(number: number) }
          tickets.each { |ticket| NotificationSubscription.create!(user: follower, subscribable: ticket, mode: 'follow') }
          Current.user = writer
          Actors::ApplyTicketChanges.call(project: source, ticket_ids: tickets.map(&:id),
                                          changes: [{ 'field' => 'status', 'value' => 'wip' }], current_user: writer)
        end
        Current.reset
        ActsAsTenant.current_tenant = nil
        drain_outbox
      end
    end

    def lose_tickets
      ActsAsTenant.with_tenant(organisation) do
        ProjectPermission.where(user: follower).find_each { |pp| pp.update!(tickets_access: 'no_access', documents_access: 'read_only') }
      end
    end

    it 'lists the numbers while the person reads tickets' do
      expect(mentions?(rest_body(follower), 7705)).to be true
    end

    it 'shows neither the numbers nor the ticket ids once the right is gone' do
      lose_tickets
      body = rest_body(follower)
      expect(mentions?(body, 7705)).to be false
      expect(mentions?(body, 7706)).to be false
      tickets.each { |ticket| expect(body).not_to include(ticket.id) }
    end
  end
end
