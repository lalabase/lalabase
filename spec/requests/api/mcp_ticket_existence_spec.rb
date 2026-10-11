# frozen_string_literal: true

require 'rails_helper'

# A ticket the token owner may not read answers EXACTLY like a ticket that does
# not exist: same text (up to the address), same isError, same machine field.
# Otherwise "Not authorized." against "No ticket found" tells a caller with
# access to the project, but not to its tickets, which ticket numbers exist —
# and ticket numbers count up, so they can be tried one by one.
#
# Covers every MCP tool that addresses a single ticket: get_ticket (by id and by
# number), post_comment, create_time_session and update_ticket. The write tools
# write nothing (update_ticket's own spec counts its writes).
RSpec.describe 'MCP: a ticket without read access looks like a missing one', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  # The project is reachable (notes), its tickets are not.
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, notes_access: :read_only)
      TimeSessionPermission.create!(user: user, project: project, can_create_own: true)
    end
  end

  let!(:hidden) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Vertrauliche Planung')
    end
  end

  # The same project with read access to its tickets: proves the answers below
  # are about rights, not about a tool that finds nothing anywhere.
  let(:readable_project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:readable) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: readable_project, tickets_access: :read_write)
      TimeSessionPermission.create!(user: user, project: readable_project, can_create_own: true)
      create(:ticket, project: readable_project, organisation: organisation, creator: user, title: 'Offen')
    end
  end

  def build_pat(owner, organisation, read_only:)
    token = build(:personal_access_token, user: owner, organisations: [organisation], read_only: read_only)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  let(:read_pat) { build_pat(user, organisation, read_only: true) }
  let(:write_pat) { build_pat(user, organisation, read_only: false) }

  def call_tool(pat_record, name, arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{pat_record.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch('result')
  end

  # The whole answer with the address replaced: what a caller can tell apart.
  def seen(result, address)
    result.to_json.gsub(address.to_s, 'ADDRESS')
  end

  def counts
    ActsAsTenant.without_tenant { [Post.count, TimeSession.count] }
  end

  shared_examples 'a hidden ticket answers like a missing one' do |tool, pat_name, extra|
    it "#{tool} by id" do
      pat = public_send(pat_name)
      missing_id = SecureRandom.uuid
      before = counts
      hidden_answer = call_tool(pat, tool, { project_id: project.id, ticket_id: hidden.id }.merge(extra))
      missing_answer = call_tool(pat, tool, { project_id: project.id, ticket_id: missing_id }.merge(extra))

      expect(missing_answer['_meta']).to eq('lalabase/kind' => 'empty')
      expect(seen(hidden_answer, hidden.id)).to eq(seen(missing_answer, missing_id))
      expect(hidden_answer.to_json).not_to include('Vertrauliche Planung')
      expect(counts).to eq(before)
    end

    it "#{tool} still serves a ticket that may be read" do
      pat = public_send(pat_name)
      answer = call_tool(pat, tool, { project_id: readable_project.id, ticket_id: readable.id }.merge(extra))
      expect(answer['_meta']).to eq('lalabase/kind' => 'ok')
    end
  end

  it_behaves_like 'a hidden ticket answers like a missing one', 'get_ticket', :read_pat, {}
  it_behaves_like 'a hidden ticket answers like a missing one', 'post_comment', :write_pat, { body: 'Hallo' }
  it_behaves_like 'a hidden ticket answers like a missing one', 'create_time_session', :write_pat,
                  { duration_minutes: 30 }
  it_behaves_like 'a hidden ticket answers like a missing one', 'update_ticket', :write_pat, { title: 'Neu' }

  it 'get_ticket by number: the numbers of hidden tickets cannot be told from numbers never used' do
    unused = hidden.number + 1000
    hidden_answer = call_tool(read_pat, 'get_ticket', { project_id: project.id, number: hidden.number.to_s })
    missing_answer = call_tool(read_pat, 'get_ticket', { project_id: project.id, number: unused.to_s })

    expect(missing_answer['_meta']).to eq('lalabase/kind' => 'empty')
    expect(seen(hidden_answer, "number #{hidden.number}")).to eq(seen(missing_answer, "number #{unused}"))
    expect(hidden_answer.to_json).not_to include('Vertrauliche Planung')
  end

  # The read scope narrows by RIGHTS, not by person: a ticket somebody else
  # created is commented on like one's own.
  it 'post_comment comments on a readable ticket somebody else created' do
    other = create(:user)
    foreign = ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: other, organisation: organisation, role: role, active: true)
      create(:ticket, project: readable_project, organisation: organisation, creator: other, title: 'Von Ben')
    end
    readable # the permissions of the readable project

    answer = nil
    expect do
      answer = call_tool(write_pat, 'post_comment',
                         { project_id: readable_project.id, ticket_id: foreign.id, body: 'Schaue ich mir an.' })
    end.to change { counts.first }.by(1)
    expect(answer['_meta']).to eq('lalabase/kind' => 'ok')
    post = ActsAsTenant.without_tenant { Post.order(:created_at).last }
    expect([post.ticket_id, post.user_id, post.plain_text_version]).to eq([foreign.id, user.id, 'Schaue ich mir an.'])
  end

  # The inbox answers by the same right (Notification.readable): a notification
  # about the hidden ticket, received while it was readable, shows neither its
  # id, nor its number, nor its title (which may have changed since).
  it 'list_notifications leaves out a notification about a hidden ticket' do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation, project: project, notifiable: hidden,
                            channel: 'in_app', state: 'queued')
    end
    answer = call_tool(read_pat, 'list_notifications', { status: 'all' })
    expect(JSON.parse(answer.dig('content', 0, 'text'))['data']).to eq([])
    expect(answer.to_json).not_to include(hidden.id)
    expect(answer.to_json).not_to include('Vertrauliche Planung')
  end

  it 'get_ticket by number still serves a ticket that may be read' do
    answer = call_tool(read_pat, 'get_ticket', { project_id: readable_project.id, number: readable.number.to_s })
    expect(answer['_meta']).to eq('lalabase/kind' => 'ok')
  end
end
