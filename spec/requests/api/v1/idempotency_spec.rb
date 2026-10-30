# frozen_string_literal: true

require 'rails_helper'

# What: an Idempotency-Key header on a /api/v1 write replays the first answer
#   (status and body) instead of writing again (cli_rest_plan D7). Same table as
#   the MCP idempotency keys, keyed per token.
# Why: a client retries a write after a timeout without knowing whether it
#   landed. Without the key that retry is a second comment or a second booking.
#   The threats pinned here: a replay reaching another token or a read-only one,
#   a reused key with other arguments still writing, a failed write blocking its
#   correction, and a key crossing between MCP and REST to hand out a foreign answer.
RSpec.describe 'API V1 idempotency', :ci_guard, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }

  def build_pat(read_only: false, owner: user)
    build(:personal_access_token, user: owner, organisations: [organisation], read_only: read_only).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:pat) { build_pat }

  def headers(key = nil, token: pat)
    h = { 'Authorization' => "Bearer #{token.token}" }
    h['Idempotency-Key'] = key if key
    h
  end

  def snapshot = [response.status, response.body]

  def posts_count = Post.where(ticket: ticket).count

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: project, tickets_access: :read_write)
  end

  after { ActsAsTenant.current_tenant = nil }

  def comment(body, key:, token: pat)
    post "/api/v1/tickets/#{ticket.id}/posts", params: { post: { body: body } }, headers: headers(key, token: token)
  end

  def comment_with_binary_parameter(bytes)
    boundary = 'binary-parameter'
    raw = "--#{boundary}\r\nContent-Disposition: form-data; name=\"post[body]\"\r\n\r\nHallo\r\n".b
    raw << "--#{boundary}\r\nContent-Disposition: form-data; name=\"ignored\"\r\nContent-Type: text/plain; charset=binary\r\n\r\n".b
    raw << bytes.b << "\r\n--#{boundary}--\r\n".b
    post "/api/v1/tickets/#{ticket.id}/posts", params: raw,
                                               headers: headers('binary-parameter').merge('CONTENT_TYPE' => "multipart/form-data; boundary=#{boundary}")
  end

  describe 'POST /api/v1/tickets/:ticket_id/posts' do
    it 'replays the first answer for a repeated key and writes once' do
      expect { comment('Hallo', key: 'k-1') }.to change { posts_count }.by(1)
      first = snapshot
      expect(first.first).to eq(201)

      expect { comment('Hallo', key: 'k-1') }.not_to(change { posts_count })
      expect(snapshot).to eq(first)
    end

    it 'writes twice without a key, as before' do
      expect { 2.times { comment('Hallo', key: nil) } }.to change { posts_count }.by(2)
    end

    it 'treats a blank key as no key' do
      expect { 2.times { comment('Hallo', key: '  ') } }.to change { posts_count }.by(2)
    end

    it 'refuses the key with other arguments as invalid_input and writes nothing' do
      comment('Hallo', key: 'k-2')
      expect { comment('Anders', key: 'k-2') }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'invalid_input', 'error' => 'idempotency_key_reused')
    end

    it 'does not remember a failed write, so the corrected retry writes' do
      post "/api/v1/tickets/#{ticket.id}/posts", params: { post: { body: '' } }, headers: headers('k-3')
      expect(response).to have_http_status(:unprocessable_content)
      expect { comment('Jetzt richtig', key: 'k-3') }.to change { posts_count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "keeps one token's key away from another token" do
      comment('Hallo', key: 'k-4')
      expect { comment('Hallo', key: 'k-4', token: build_pat) }.to change { posts_count }.by(1)
    end

    it 'refuses a read-only token before any replay' do
      comment('Hallo', key: 'k-5')
      read_only = build_pat(read_only: true)
      McpIdempotencyKey.find_by!(idempotency_key: 'k-5').update!(personal_access_token_id: read_only.id)
      comment('Hallo', key: 'k-5', token: read_only)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq('error' => 'forbidden', 'code' => 'read_only')
    end

    # The stored fingerprint is what this very request's parameters would give
    # without method and path: only those two keep the surfaces apart.
    it 'never replays an answer stored by an MCP call under the same key' do
      bare = Mcp::IdempotencyStore.fingerprint('params' => { 'post' => { 'body' => 'Hallo' } })
      McpIdempotencyKey.create!(personal_access_token: pat, idempotency_key: 'k-6', tool_name: 'post_comment',
                                request_fingerprint: bare, response_content: 'MCP-ANSWER')
      expect { comment('Hallo', key: 'k-6') }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include('MCP-ANSWER')
    end

    it 'never lets MCP replay an answer stored by REST under the same key' do
      comment('Hallo', key: 'k-7')
      rest_body = response.body
      post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                                 params: { name: 'post_comment',
                                           arguments: { project_id: project.id, ticket_id: ticket.id, body: 'Hallo',
                                                        idempotency_key: 'k-7' } } }.to_json,
                       headers: headers.merge('CONTENT_TYPE' => 'application/json')
      result = response.parsed_body['result']
      expect(result['isError']).to be(true)
      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
      expect(response.body).not_to include(JSON.parse(rest_body).dig('data', 'id'))
    end
  end

  describe 'the request the key belongs to' do
    let(:other_ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }

    it 'replays a successful write with ignored binary input, but refuses different bytes' do
      expect { comment_with_binary_parameter("x\xFF") }.to change { posts_count }.by(1)
      first = snapshot
      expect(first.first).to eq(201)

      expect { comment_with_binary_parameter("x\xFF") }.not_to(change { posts_count })
      expect(snapshot).to eq(first)

      expect { comment_with_binary_parameter("x\xFE") }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'idempotency_key_reused')
    end

    # The ticket is in the path only: without the path in the fingerprint the
    # comment on the second ticket would get the first ticket's answer and never land.
    it 'refuses the key on another ticket with the same body, writing nothing there' do
      comment('Hallo', key: 'p-1')
      expect do
        post "/api/v1/tickets/#{other_ticket.id}/posts", params: { post: { body: 'Hallo' } }, headers: headers('p-1')
      end.not_to(change { Post.where(ticket: other_ticket).count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'idempotency_key_reused', 'code' => 'invalid_input')
    end

    it 'refuses the key on another method to the same path' do
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: 'new' } }, headers: headers('p-2')
      put "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: 'new' } }, headers: headers('p-2')
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'idempotency_key_reused')
    end
  end

  # Deliberate: a replay checks no rights. It hands the token the answer that
  # very token already received, nothing new; a fresh key gets the rights check.
  it 'replays to the same token after its project rights are gone, while a new key is refused' do
    comment('Hallo', key: 'r-1')
    first = snapshot
    ProjectPermission.find_by!(user: user, project: project).destroy!
    comment('Hallo', key: 'r-1')
    expect(snapshot).to eq(first)
    expect { comment('Hallo', key: 'r-2') }.not_to(change { posts_count })
    expect(response).to have_http_status(:not_found)
  end

  describe 'a key the store cannot hold' do
    # The unique index on (token, key) holds about 2.7 KB; a longer key used to
    # write, fail to be stored with a 500, and write again on every retry.
    it 'refuses a key longer than the limit before writing' do
      long = 'k' * (Mcp::IdempotencyStore::MAX_KEY_LENGTH + 1)
      expect { comment('Hallo', key: long) }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'invalid_idempotency_key', 'code' => 'invalid_input')
    end

    # Bytes, not characters: 128 umlauts are 256 bytes.
    it 'counts the limit in bytes' do
      expect { comment('Hallo', key: 'ä' * 128) }.not_to(change { posts_count })
      expect(response).to have_http_status(:unprocessable_content)
      expect { comment('Hallo', key: "#{'ä' * 127}k") }.to change { posts_count }.by(1)
    end

    # PostgreSQL refuses both in a text column; they used to answer a 500.
    def expect_invalid_key
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'invalid_idempotency_key', 'code' => 'invalid_input')
    end

    it 'refuses a key that is not valid UTF-8, writing nothing' do
      expect { comment('Hallo', key: "k\xFFx".b) }.not_to(change { posts_count })
      expect_invalid_key
    end

    it 'refuses a key with a NUL byte, writing nothing' do
      expect { comment('Hallo', key: "k\u0000x") }.not_to(change { posts_count })
      expect_invalid_key
    end

    it 'accepts a key of exactly the limit' do
      key = 'k' * Mcp::IdempotencyStore::MAX_KEY_LENGTH
      expect { 2.times { comment('Hallo', key: key) } }.to change { posts_count }.by(1)
    end

    # The header is read by the rule the MCP argument is read by
    # (Mcp::IdempotencyStore.client_key): surrounding whitespace goes before the
    # key is counted or stored, so the bare key replays the first answer.
    it 'drops surrounding whitespace before it counts, as MCP does' do
      key = 'k' * Mcp::IdempotencyStore::MAX_KEY_LENGTH
      expect { comment('Hallo', key: " #{key}\t") }.to change { posts_count }.by(1)
      first = snapshot
      expect(first.first).to eq(201)

      expect { comment('Hallo', key: key) }.not_to(change { posts_count })
      expect(snapshot).to eq(first)
    end

    it 'names the header and the bound in its refusal' do
      comment('Hallo', key: 'k' * (Mcp::IdempotencyStore::MAX_KEY_LENGTH + 1))
      expect(response.parsed_body).to eq('error' => 'invalid_idempotency_key', 'code' => 'invalid_input',
                                         'message' => 'Idempotency-Key must be valid UTF-8 without NUL, at most 255 bytes')
    end
  end

  # A malformed JSON body answers like any bad request, with a code, whether
  # or not the request carries a key.
  it 'answers an unreadable JSON body with a key as invalid_input, writing nothing' do
    expect do
      post "/api/v1/tickets/#{ticket.id}/posts", params: '{bad',
                                                 headers: headers('j-1').merge('CONTENT_TYPE' => 'application/json')
    end.not_to(change { posts_count })
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to include('error' => 'bad_request', 'code' => 'invalid_input')
  end

  describe 'the other writes' do
    before do
      create(:time_session_permission, user: user, project: project)
    end

    it 'replays a ticket creation' do
      create_ticket = lambda do
        post "/api/v1/projects/#{project.id}/tickets", params: { ticket: { title: 'Neu' } }, headers: headers('t-1')
      end
      expect { 2.times { create_ticket.call } }.to change { Ticket.where(project: project).count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it 'replays a ticket update without writing again' do
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: 'new' } }, headers: headers('u-1')
      first = snapshot
      expect(Actors::SaveTicket).not_to receive(:call)
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: 'new' } }, headers: headers('u-1')
      expect(snapshot).to eq(first)
    end

    it 'replays a time booking' do
      book = lambda do
        post "/api/v1/tickets/#{ticket.id}/time_sessions", params: { time_session: { duration_minutes: 30 } },
                                                           headers: headers('b-1')
      end
      expect { 2.times { book.call } }.to change { TimeSession.where(ticket: ticket).count }.by(1)
      expect(response).to have_http_status(:created)
    end

    describe 'notifications' do
      def notification(state: 'queued')
        create(:notification, recipient: user, actor: create(:user), organisation: organisation, notifiable: ticket,
                              state: state, event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
                              payload: { 'action' => 'commented' })
      end

      it 'replays mark_as_read with the first read_at' do
        row = notification
        post "/api/v1/notifications/#{row.id}/mark_as_read", headers: headers('n-1')
        first = snapshot
        travel 1.hour do
          post "/api/v1/notifications/#{row.id}/mark_as_read", headers: headers('n-1')
        end
        expect(snapshot).to eq(first)
      end

      it 'replays archive' do
        row = notification
        post "/api/v1/notifications/#{row.id}/archive", headers: headers('n-2')
        first = snapshot
        expect_any_instance_of(Notification).not_to receive(:archive!)
        post "/api/v1/notifications/#{row.id}/archive", headers: headers('n-2')
        expect(snapshot).to eq(first)
      end

      it 'replays mark_all_as_read without touching a row that arrived in between' do
        notification
        post '/api/v1/notifications/mark_all_as_read', headers: headers('n-3')
        first = snapshot
        later = notification
        post '/api/v1/notifications/mark_all_as_read', headers: headers('n-3')
        expect(snapshot).to eq(first)
        expect(later.reload.state).to eq('queued')
      end
    end
  end
end
