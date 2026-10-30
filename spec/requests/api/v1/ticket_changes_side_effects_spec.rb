# frozen_string_literal: true

require 'rails_helper'

# What: the side effects of POST /api/v1/tickets/:id/changes against the MCP tool
#   update_ticket (REST R3b).
# Type: request spec, both writes over HTTP, the jobs drained as a worker runs them.
# Why: one rule, two hulls: what follows a write must not depend on the surface.
#   Two tickets that differ only in their number take the same change, one through
#   REST, one through MCP, and their activities, bulk runs, outbox events,
#   notifications (by recipient and channel) and subscriptions must match. The
#   tool's own spec holds the tool to the web write, so this one holds REST to
#   both. Exactly one activity each: a second actor call or a second save would
#   add one.
RSpec.describe 'REST ticket changes: side effects equal the MCP write', :ci_guard, type: :request do
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

  def over_rest(ticket, fields)
    post "/api/v1/tickets/#{ticket.id}/changes", params: { change: fields }.to_json,
                                                 headers: { 'Authorization' => "Bearer #{write_pat.token}", 'Content-Type' => 'application/json' }
    expect(response).to have_http_status(:ok)
  end

  def over_mcp(ticket, fields)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call',
             params: { name: 'update_ticket', arguments: { project_id: project.id, ticket_id: ticket.id }.merge(fields) } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{write_pat.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).fetch('result')['_meta']).to eq('lalabase/kind' => 'ok')
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
        activities: activities.map { |activity| [activity.key, activity.actor_id, activity.parameters.keys.sort] },
        outbox: OutboxEvent.where(activity_id: activities.map(&:id)).count,
        runs: TicketBulkRun.where('jsonb_exists(results, ?)', ticket.id).pluck(:user_id, :change_list, :changed_count, :failed_count),
        notifications: Notification.where(notifiable: ticket).where.not(id: since[:notifications])
                                   .pluck(:recipient_id, :channel, :event_type).sort,
        subscriptions: NotificationSubscription.where(subscribable: ticket).pluck(:user_id, :mode, :source).sort
      }
    end
  end

  # Both writes in one queue, then the jobs of both, so neither side runs with a
  # warmer world than the other. `prepare` runs on each twin before the baseline.
  def compare(fields, prepare: nil)
    rest_ticket, mcp_ticket = twins
    with_test_queue_adapter do
      Prosopite.pause { [rest_ticket, mcp_ticket].each { |ticket| prepare.call(ticket) } } if prepare
      drain
      since = baseline
      over_rest(rest_ticket, fields)
      over_mcp(mcp_ticket, fields)
      drain
      # Reading the same things for two tickets is the spec's loop, not the app's.
      Prosopite.pause { [effects(rest_ticket, since), effects(mcp_ticket, since), rest_ticket, mcp_ticket] }
    end
  end

  def reloaded(tickets, &)
    Prosopite.pause { ActsAsTenant.without_tenant { tickets.map { |ticket| yield ticket.reload } } }
  end

  it 'runs both surfaces through the one rule' do
    expect(Tickets::Change).to receive(:parse).twice.and_call_original

    compare({ status: 'wip' })
  end

  it 'changes the status with the same trail, once' do
    rest, mcp, rest_ticket, mcp_ticket = compare({ status: 'wip' })

    expect(rest).to eq(mcp)
    expect(rest[:activities].map(&:first)).to eq(['ticket.status_changed'])
    expect(rest[:activities].dig(0, 1)).to eq(writer.id)
    expect(rest[:activities].dig(0, 2)).to include('bulk_run_id')
    expect(rest[:runs].size).to eq(1)
    expect(rest[:outbox]).to eq(1)
    expect(rest[:notifications]).not_to be_empty
    expect(rest[:notifications].map(&:first)).not_to include(writer.id)
    expect(reloaded([rest_ticket, mcp_ticket], &:custom_attributes)).to all(eq('status' => 'wip', 'priority' => 'high'))
  end

  it 'assigns with the same trail, once' do
    rest, mcp, rest_ticket, mcp_ticket = compare({ add_assignee_ids: ['me'] })

    expect(rest).to eq(mcp)
    expect(rest[:activities].map(&:first)).to eq(['ticket.assigned'])
    expect(rest[:runs].size).to eq(1)
    expect(rest[:notifications]).not_to be_empty
    expect(reloaded([rest_ticket, mcp_ticket]) { |ticket| ticket.assignees.map(&:id).sort })
      .to all(eq([colleague.id, writer.id].sort))
  end

  # The assignment of the colleague is made the way the board makes it, so it
  # carries its subscription; taking it away must take both, and say so once.
  it 'unassigns with the same trail, once' do
    assign_colleague = lambda do |ticket|
      ActsAsTenant.with_tenant(organisation) do
        ticket.ticket_assignments.delete_all
        TicketAssignmentSync.call(ticket: ticket, assignee_ids: [colleague.id], is_new_ticket: false)
      end
    end

    rest, mcp, rest_ticket, mcp_ticket = compare({ remove_assignee_ids: [colleague.id] }, prepare: assign_colleague)

    expect(rest).to eq(mcp)
    expect(rest[:activities].map(&:first)).to eq(['ticket.unassigned'])
    expect(rest[:subscriptions].map(&:first)).not_to include(colleague.id)
    expect(reloaded([rest_ticket, mcp_ticket]) { |ticket| ticket.assignees.to_a }).to all(be_empty)
  end

  it 'renames with the same trail, once, and without a run' do
    rest, mcp, rest_ticket, mcp_ticket = compare({ title: 'Login bricht in Safari ab' })

    expect(rest).to eq(mcp)
    expect(rest[:activities].map(&:first)).to eq(['ticket.title_changed'])
    expect(rest[:activities].dig(0, 1)).to eq(writer.id)
    expect(rest[:runs]).to be_empty
    expect(rest[:notifications]).not_to be_empty
    expect(reloaded([rest_ticket, mcp_ticket], &:title)).to all(eq('Login bricht in Safari ab'))
  end
end
