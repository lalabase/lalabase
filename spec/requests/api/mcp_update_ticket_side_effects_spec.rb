# frozen_string_literal: true

require 'rails_helper'

# What: the side effects of update_ticket against the web write it reuses
#   (terminal client S2).
# Type: request spec, both writes over HTTP, the jobs drained as a worker runs them.
# Why: the tool adds no write path, so what follows a write must be the same as in
#   the browser: a status change like a board drag, an assignment like the head's
#   people menu, a rename like the edit form. Two tickets that differ only in their
#   number take the same change, one through the web, one through MCP, and their
#   activities, outbox events and notifications (by recipient and channel) must
#   match. Exactly one activity each: a second actor call, a touch or a second save
#   would add one.
RSpec.describe 'MCP update_ticket: side effects equal the web write', type: :request do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user, first_name: 'Willi', last_name: 'Writer') }
  let(:follower) { create(:user, first_name: 'Fritz', last_name: 'Follower') }
  let(:colleague) { create(:user, first_name: 'Anna', last_name: 'Berg') }
  let(:project) { create(:project, organisation: organisation) }

  before do
    bulk_project_setup
    bulk_member(follower)
    bulk_member(colleague)
    ActsAsTenant.current_tenant = nil
  end

  let(:write_pat) do
    token = build(:personal_access_token, user: writer, organisations: [organisation], read_only: false)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  # Two tickets that differ only in their number. The follower created them, so
  # the creator subscription makes them a follower of both; the colleague is
  # assigned to both.
  def twins
    ActsAsTenant.with_tenant(organisation) do
      Array.new(2) do
        create(:ticket, project: project, organisation: organisation, creator: follower, title: 'Login bricht ab',
                        assignees: [colleague], custom_attributes: { 'status' => 'open', 'priority' => 'high' })
      end
    end
  end

  def call_tool(arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call',
             params: { name: 'update_ticket', arguments: arguments } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{write_pat.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    result = JSON.parse(response.body).fetch('result')
    expect(result['_meta']).to eq('lalabase/kind' => 'ok')
  end

  # Each job looks up its tenant once when it is deserialized; run back to
  # back here, Prosopite would read those lookups as an N+1.
  def drain
    Prosopite.pause
    drain_enqueued_jobs
  ensure
    Prosopite.resume
  end

  def baseline
    ActsAsTenant.without_tenant { { activities: Activity.ids, notifications: Notification.ids } }
  end

  # What a write left behind for one ticket. Parameters are compared by their
  # keys: values like the run id and the ticket number differ by construction.
  def effects(ticket, since)
    ActsAsTenant.without_tenant do
      activities = Activity.where(trackable: ticket).where.not(id: since[:activities]).order(:created_at).to_a
      {
        activities: activities.map { |activity| [activity.key, activity.parameters.keys.sort] },
        outbox: OutboxEvent.where(activity_id: activities.map(&:id)).count,
        # The runs that name this ticket: one for a board drag, none for a rename.
        runs: TicketBulkRun.where('jsonb_exists(results, ?)', ticket.id).count,
        notifications: Notification.where(notifiable: ticket).where.not(id: since[:notifications])
                                   .pluck(:recipient_id, :channel, :event_type).sort,
        # The state, not a delta: an unassignment takes the assignment's
        # subscription with it.
        subscriptions: NotificationSubscription.where(subscribable: ticket).pluck(:user_id, :mode, :source).sort
      }
    end
  end

  # Both writes in one queue, then the jobs of both, so neither side runs with a
  # warmer world than the other.
  # `prepare` runs on each twin before the baseline, inside the queue.
  def compare(prepare: nil)
    web_ticket, mcp_ticket = twins
    with_test_queue_adapter do
      # The setup's own loop over the twins, not the app's.
      Prosopite.pause { [web_ticket, mcp_ticket].each { |ticket| prepare.call(ticket) } } if prepare
      drain
      since = baseline
      sign_in writer
      yield web_ticket, mcp_ticket
      drain
      # Reading the same things for two tickets is the spec's loop, not the app's.
      Prosopite.pause { [effects(web_ticket, since), effects(mcp_ticket, since), web_ticket, mcp_ticket] }
    end
  end

  def reloaded(tickets, &)
    Prosopite.pause { ActsAsTenant.without_tenant { tickets.map { |ticket| yield ticket.reload } } }
  end

  it 'changes the status like a board drag' do
    web, mcp, web_ticket, mcp_ticket = compare do |web_ticket, mcp_ticket|
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, web_ticket),
            params: { attribute_name: 'status', value: 'wip' }, as: :json
      expect(response).to have_http_status(:ok)
      call_tool(project_id: project.id, ticket_id: mcp_ticket.id, status: 'wip')
    end

    expect(mcp).to eq(web)
    expect(mcp[:activities]).to eq([['ticket.status_changed', mcp[:activities].dig(0, 1)]])
    expect(mcp[:activities].dig(0, 1)).to include('bulk_run_id')
    expect(mcp[:runs]).to eq(1)
    expect(mcp[:notifications]).not_to be_empty
    expect(mcp[:notifications].map(&:first)).not_to include(writer.id)
    expect(reloaded([web_ticket, mcp_ticket], &:custom_attributes)).to all(eq('status' => 'wip', 'priority' => 'high'))
  end

  it 'assigns like the people menu in the ticket head' do
    web, mcp, web_ticket, mcp_ticket = compare do |web_ticket, mcp_ticket|
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, web_ticket),
            params: { attribute_name: 'assignees', add: [writer.id] }, as: :json
      expect(response).to have_http_status(:ok)
      call_tool(project_id: project.id, ticket_id: mcp_ticket.id, add_assignee_ids: ['me'])
    end

    expect(mcp).to eq(web)
    expect(mcp[:activities].map(&:first)).to eq(['ticket.assigned'])
    expect(mcp[:runs]).to eq(1)
    expect(mcp[:notifications]).not_to be_empty
    expect(reloaded([web_ticket, mcp_ticket]) { |ticket| ticket.assignees.map(&:id).sort })
      .to all(eq([colleague.id, writer.id].sort))
  end

  # The assignment of the colleague is made the way the board makes it, so it
  # carries its subscription; taking it away must take both, and say so once.
  it 'unassigns like the people menu in the ticket head' do
    assign_colleague = lambda do |ticket|
      ActsAsTenant.with_tenant(organisation) do
        ticket.ticket_assignments.delete_all
        TicketAssignmentSync.call(ticket: ticket, assignee_ids: [colleague.id], is_new_ticket: false)
      end
    end

    web, mcp, web_ticket, mcp_ticket = compare(prepare: assign_colleague) do |web_ticket, mcp_ticket|
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, web_ticket),
            params: { attribute_name: 'assignees', remove: [colleague.id] }, as: :json
      expect(response).to have_http_status(:ok)
      call_tool(project_id: project.id, ticket_id: mcp_ticket.id, remove_assignee_ids: [colleague.id])
    end

    expect(mcp).to eq(web)
    expect(mcp[:activities].map(&:first)).to eq(['ticket.unassigned'])
    expect(mcp[:subscriptions].map(&:first)).not_to include(colleague.id)
    expect(reloaded([web_ticket, mcp_ticket]) { |ticket| ticket.assignees.to_a }).to all(be_empty)
  end

  it 'renames like the edit form' do
    web, mcp, web_ticket, mcp_ticket = compare do |web_ticket, mcp_ticket|
      patch organisation_project_ticket_path(organisation, project, web_ticket),
            params: { ticket: { title: 'Login bricht in Safari ab' } }
      expect(response).to have_http_status(:redirect)
      call_tool(project_id: project.id, ticket_id: mcp_ticket.id, title: 'Login bricht in Safari ab')
    end

    expect(mcp).to eq(web)
    expect(mcp[:activities].map(&:first)).to eq(['ticket.title_changed'])
    expect(mcp[:runs]).to eq(0)
    expect(mcp[:notifications]).not_to be_empty
    expect(reloaded([web_ticket, mcp_ticket], &:title)).to all(eq('Login bricht in Safari ab'))
  end
end
