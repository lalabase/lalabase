# frozen_string_literal: true

require 'rails_helper'

# What: an MCP write whose idempotency_key the store cannot hold (more than
#   255 bytes, bytes that are no valid UTF-8, a NUL) is refused as
#   invalid_input before the tool runs: nothing written, nothing remembered. A
#   key the store can hold works as before: the write lands once and a retry
#   replays it.
# Type: request spec through /api/mcp, the gates of Mcp::ToolCall included.
# Why: the key is remembered only AFTER the write. A key too long for the unique
#   index wrote, failed to be remembered (-32603) and wrote again on every
#   retry; a key with a NUL or with bytes that are no UTF-8 ended in -32603.
#   REST refuses such a key since R0, and both surfaces ask one rule
#   (Mcp::IdempotencyStore). The project gate and the read-only gate still
#   answer first, so the refusal tells nothing about a project the token cannot
#   see.
#
# The write tools come from the registry, not from a list kept here: a write
# tool added to the surface fails this spec until it has a call in
# #write_calls.
#
# Security spec: tagged :ci_guard and listed in .github/workflows/guards.yml.
RSpec.describe 'MCP writes and an idempotency_key the store cannot hold', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end

  let!(:time_session_permission) do
    ActsAsTenant.with_tenant(organisation) do
      TimeSessionPermission.create!(user: user, project: project, can_create_own: true)
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Login bricht ab')
    end
  end

  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'queued')
    end
  end

  def build_pat(read_only:)
    token = build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  let(:write_pat) { build_pat(read_only: false) }
  let(:read_pat) { build_pat(read_only: true) }

  let(:refusal) { 'idempotency_key must be valid UTF-8 without NUL, at most 255 bytes' }
  let(:invalid_input) { { 'lalabase/code' => 'invalid_input' } }
  # A tool's own answer: a protocol error (-32603) carries no `_meta` at all.
  let(:ok) { { 'lalabase/kind' => 'ok' } }

  write_tools = Lalabase::Tools::Registry::MCP.select(&:mutating?)

  # One call per write tool that writes, and a reading of what it writes: the
  # reading changes when the write lands. Built in full for every example, so
  # the records the calls name exist before anything is measured.
  def write_calls
    {
      'create_ticket' => [{ project_id: project.id, title: 'Neu angelegt' }, -> { Ticket.count }],
      'post_comment' => [{ project_id: project.id, ticket_id: ticket.id, body: 'Hallo' }, -> { Post.count }],
      'create_time_session' => [{ project_id: project.id, ticket_id: ticket.id, duration: '0:30' },
                                -> { TimeSession.count }],
      'mark_notification_read' => [{ notification_id: notification.id }, -> { notification.reload.state }],
      'update_ticket' => [{ project_id: project.id, ticket_id: ticket.id, title: 'Neuer Titel' },
                          -> { ticket.reload.title }]
    }
  end

  def reading_of(tool_name)
    reading = write_calls.fetch(tool_name).last
    ActsAsTenant.without_tenant { reading.call }
  end

  def remembered_keys
    McpIdempotencyKey.order(:created_at).pluck(:idempotency_key)
  end

  def rpc(tool_name, arguments)
    { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool_name, arguments: arguments } }.to_json
  end

  # The JSON-RPC `result`, or the whole body when there is none (a protocol
  # error such as -32603), so a failure shows what came back.
  def post_body(token, body, content_type: 'application/json')
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{token.token}", 'CONTENT_TYPE' => content_type }
    parsed = JSON.parse(response.body)
    parsed.fetch('result', parsed)
  end

  def call_tool(token, tool_name, arguments)
    post_body(token, rpc(tool_name, arguments))
  end

  # JSON cannot be generated around bytes that are no UTF-8: the body is built
  # around a marker, and the marker is replaced by the raw bytes, or by the
  # JSON escape of a lone low surrogate, which the parser turns into such bytes.
  # Sent as text/plain: in a body sent as JSON, Rails refuses such bytes itself
  # (see 'a JSON body with bytes that are no UTF-8'), while the endpoint reads
  # the raw body whatever its type, so this is the way they reach the seam.
  def call_tool_with_raw_key(token, tool_name, arguments, raw, content_type: 'text/plain')
    post_body(token, raw_key_body(tool_name, arguments, raw), content_type: content_type)
  end

  def raw_key_body(tool_name, arguments, raw)
    marker = 'RAW-KEY-MARKER'
    rpc(tool_name, arguments.merge(idempotency_key: marker)).b.sub(marker, raw.b)
  end

  def text_of(result)
    result.dig('content', 0, 'text')
  end

  def expect_refused(result, tool_name, before)
    expect(result['isError']).to be(true)
    expect(result['_meta']).to eq(invalid_input)
    expect(text_of(result)).to eq(refusal)
    expect(reading_of(tool_name)).to eq(before)
    expect(remembered_keys).to be_empty
  end

  it 'has a write call for every write tool of the surface, and none for a tool that does not write' do
    expect(write_tools).not_to be_empty
    expect(write_calls.keys).to match_array(write_tools.map(&:tool_name))
  end

  write_tools.each do |tool|
    describe tool.tool_name do
      let(:arguments) { write_calls.fetch(tool.tool_name).first }

      it 'refuses a key of 256 bytes as invalid_input, writing and remembering nothing' do
        before = reading_of(tool.tool_name)
        expect_refused(call_tool(write_pat, tool.tool_name, arguments.merge(idempotency_key: 'k' * 256)),
                       tool.tool_name, before)
      end

      # 128 characters, 256 bytes: the limit counts bytes.
      it 'refuses 128 umlauts, counting bytes and not characters' do
        before = reading_of(tool.tool_name)
        expect_refused(call_tool(write_pat, tool.tool_name, arguments.merge(idempotency_key: 'ä' * 128)),
                       tool.tool_name, before)
      end

      it 'refuses a key with a NUL inside' do
        before = reading_of(tool.tool_name)
        expect_refused(call_tool(write_pat, tool.tool_name, arguments.merge(idempotency_key: "k#{0.chr}x")),
                       tool.tool_name, before)
      end

      it 'refuses a key with bytes that are no UTF-8' do
        before = reading_of(tool.tool_name)
        expect_refused(call_tool_with_raw_key(write_pat, tool.tool_name, arguments, "k\xFFx".b),
                       tool.tool_name, before)
      end

      it 'refuses a key the JSON parser turns into bytes that are no UTF-8 (a lone low surrogate)' do
        before = reading_of(tool.tool_name)
        expect_refused(call_tool_with_raw_key(write_pat, tool.tool_name, arguments, 'k\\udc00x'),
                       tool.tool_name, before)
      end

      # 127 umlauts and one letter: 255 bytes, 128 characters.
      it 'writes and remembers a key of 255 bytes, umlauts included, and replays it without running again' do
        key = "#{'ä' * 127}k"
        before = reading_of(tool.tool_name)

        first = call_tool(write_pat, tool.tool_name, arguments.merge(idempotency_key: key))
        expect(first['_meta']).to eq(ok)
        expect(reading_of(tool.tool_name)).not_to eq(before)
        expect(remembered_keys).to eq([key])

        expect(tool).not_to receive(:execute)
        again = call_tool(write_pat, tool.tool_name, arguments.merge(idempotency_key: key))
        expect(again['_meta']).to eq(ok)
        expect(text_of(again)).to eq(text_of(first))
        expect(remembered_keys).to eq([key])
      end
    end
  end

  describe 'reading the key' do
    let(:comment) { write_calls.fetch('post_comment').first }

    it 'drops surrounding whitespace before it counts, so 255 bytes between spaces are a key' do
      key = 'k' * 255
      before = reading_of('post_comment')

      first = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: " #{key}\t"))
      expect(first['_meta']).to eq(ok)
      expect(remembered_keys).to eq([key])

      again = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: key))
      expect(again['_meta']).to eq(ok)
      expect(text_of(again)).to eq(text_of(first))
      expect(reading_of('post_comment')).to eq(before + 1)
    end

    it 'treats a blank key as none: writes on every call and remembers nothing' do
      before = reading_of('post_comment')
      first = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: '   '))
      second = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: ''))

      expect([first, second].map { |result| result['_meta'] }).to all(eq(ok))
      expect(reading_of('post_comment')).to eq(before + 2)
      expect(remembered_keys).to be_empty
    end

    # The argument arrives as UTF-8, where Unicode spaces are blank: no key, as
    # before. (A REST header arrives as binary, where the same bytes are a key;
    # pinned in the store spec.)
    it 'reads a key of Unicode spaces only as none' do
      before = reading_of('post_comment')
      first = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: "\u00A0"))
      second = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: "\u00A0\u3000"))

      expect([first, second].map { |result| result['_meta'] }).to all(eq(ok))
      expect(reading_of('post_comment')).to eq(before + 2)
      expect(remembered_keys).to be_empty
    end

    # The failure the bound exists for: a random key of 4 KB does not fit the
    # unique index. It used to write, fail to be remembered with -32603 and
    # write again on the retry.
    it 'refuses a key far beyond the index before the write, so its retry cannot write twice' do
      key = SecureRandom.hex(2048)
      before = reading_of('post_comment')

      first = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: key))
      retry_answer = call_tool(write_pat, 'post_comment', comment.merge(idempotency_key: key))

      expect([first, retry_answer].map { |result| result['_meta'] }).to all(eq(invalid_input))
      expect(reading_of('post_comment')).to eq(before)
      expect(remembered_keys).to be_empty
    end
  end

  # Rails reads a body sent as JSON before the endpoint runs and refuses such
  # bytes there: nothing reaches the seam. Pinned so the text/plain detour of
  # the examples above keeps its reason.
  describe 'a JSON body with bytes that are no UTF-8' do
    it 'is refused by Rails with 400 before the endpoint, writing and remembering nothing' do
      before = reading_of('post_comment')
      post '/api/mcp', params: raw_key_body('post_comment', write_calls.fetch('post_comment').first, "k\xFFx".b),
                       headers: { 'Authorization' => "Bearer #{write_pat.token}", 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:bad_request)
      expect(reading_of('post_comment')).to eq(before)
      expect(remembered_keys).to be_empty
    end
  end

  # The project gate and the read-only gate answer before the key: a key the
  # store cannot hold must not turn a foreign project or a read-only token into
  # an answer of its own.
  describe 'the gates before the key' do
    let(:comment) { write_calls.fetch('post_comment').first }
    let(:foreign_project) do
      ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    end

    it 'answers a read-only token with read_only, writing nothing' do
      before = reading_of('post_comment')
      result = call_tool(read_pat, 'post_comment', comment.merge(idempotency_key: 'k' * 256))

      expect(result['isError']).to be(true)
      expect(result['_meta']).to eq('lalabase/code' => 'read_only')
      expect(reading_of('post_comment')).to eq(before)
    end

    it 'answers a read-only token on the token-scoped write with read_only, leaving the row unread' do
      result = call_tool(read_pat, 'mark_notification_read',
                         { notification_id: notification.id, idempotency_key: 'k' * 256 })

      expect(result['_meta']).to eq('lalabase/code' => 'read_only')
      expect(notification.reload.state).to eq('queued')
    end

    it 'answers a read-only token with read_only for a key that is no UTF-8' do
      result = call_tool_with_raw_key(read_pat, 'post_comment', comment, "k\xFFx".b)

      expect(result['_meta']).to eq('lalabase/code' => 'read_only')
    end

    it 'answers a project of another organisation as with any key: not_found' do
      foreign = comment.merge(project_id: foreign_project.id)
      long = call_tool(write_pat, 'post_comment', foreign.merge(idempotency_key: 'k' * 256))
      short = call_tool(write_pat, 'post_comment', foreign.merge(idempotency_key: 'k'))

      expect(long['_meta']).to eq('lalabase/code' => 'not_found')
      expect(long).to eq(short)
    end

    it 'answers a project that does not exist as with any key: not_found' do
      missing = comment.merge(project_id: SecureRandom.uuid)
      result = call_tool_with_raw_key(write_pat, 'post_comment', missing, "k\xFFx".b)

      expect(result['_meta']).to eq('lalabase/code' => 'not_found')
      expect(text_of(result)).to eq('Project not found or not accessible.')
    end
  end

  # A read tool is not offered the argument and ignores whatever it holds.
  describe 'a read tool' do
    it 'ignores a key of 256 bytes' do
      result = call_tool(read_pat, 'list_tickets', { project_id: project.id, idempotency_key: 'k' * 256 })

      expect(result['_meta']).to eq(ok)
    end

    it 'ignores a key with bytes that are no UTF-8' do
      result = call_tool_with_raw_key(read_pat, 'list_tickets', { project_id: project.id }, "k\xFFx".b)

      expect(result['_meta']).to eq(ok)
    end
  end
end
