# frozen_string_literal: true

require 'rails_helper'

# What: summarize_time_sessions over POST /api/mcp (terminal client S6: the booked
#   time of a ticket, for the meta bar of the client's ticket view).
# Why: the tool decides own-vs-all itself (TimeSessions::ViewingScope), and the MCP
#   seam only gates the project. A token must never see minutes its owner may not
#   see in the app: not under the "own" tier, not through a foreign creator UUID,
#   not without a permission row, not through a ticket of another project or one
#   the owner may not read, not in a project outside the token's reach. And the
#   answer must not tell a missing project or ticket from a hidden one.
RSpec.describe 'MCP summarize_time_sessions', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:colleague) { create(:user) }

  let(:project) { create(:project, organisation: organisation) }
  # Same organisation, the owner may use it and read its tickets.
  let(:other_project) { create(:project, organisation: organisation) }
  # The owner may use it (notes) and sees all time here, but reads no ticket.
  let(:time_only_project) { create(:project, organisation: organisation) }
  let(:foreign_project) do
    ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
  end

  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
  let(:other_ticket) { create(:ticket, project: other_project, organisation: organisation, creator: user) }
  let(:unreadable_ticket) { create(:ticket, project: time_only_project, organisation: organisation, creator: colleague) }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      [user, colleague].each do |member|
        create(:membership, user: member, organisation: organisation, role: role, active: true)
      end
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
      create(:project_permission, user: user, project: other_project, tickets_access: :read_write)
      create(:project_permission, user: user, project: time_only_project, tickets_access: :no_access,
                                  notes_access: :read_only)
      create(:project_permission, user: colleague, project: time_only_project, tickets_access: :read_write)

      book(user, 30, ticket: ticket)
      book(colleague, 45, ticket: ticket)
      book(colleague, 20, project: project)
      book(user, 10, ticket: other_ticket)
      book(colleague, 15, ticket: unreadable_ticket)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def book(creator, minutes, ticket: nil, project: ticket.project)
    create(:time_session, project: project, organisation: organisation, creator: creator,
                          duration: minutes, ticket: ticket, occurred_on: Time.zone.parse('2026-08-10 10:00'))
  end

  # Fail-closed: only a persisted row grants anything (ViewingScope).
  def grant_time(on, view_all:)
    create(:time_session_permission, user: user, project: on, can_view_own: true, can_view_all: view_all)
  end

  def build_pat(read_only: true, project_scopes: {})
    build(:personal_access_token, user: user, organisations: [organisation],
                                  read_only: read_only, project_scopes: project_scopes).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:pat) { build_pat }

  def rpc(method, params, token)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: method, params: params }.to_json,
                     headers: { 'Authorization' => "Bearer #{token.token}", 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body
  end

  def call(token: pat, **arguments)
    rpc('tools/call', { name: 'summarize_time_sessions', arguments: arguments }, token)['result']
  end

  def report(token: pat, **arguments)
    result = call(token: token, **arguments)
    expect(result['isError']).to be_falsey, "expected a report, got #{result.inspect}"
    JSON.parse(result.dig('content', 0, 'text'))
  end

  def minutes(token: pat, **arguments)
    report(token: token, **arguments).dig('total', 'minutes')
  end

  # No numbers at all: neither the report keys nor a single bucket.
  def expect_no_numbers(result)
    text = result.dig('content', 0, 'text').to_s
    expect(text).not_to include('total', 'buckets', 'minutes')
  end

  describe 'tools/list' do
    let(:tools) { rpc('tools/list', {}, pat).dig('result', 'tools') }

    it 'advertises the tool LAST, the pinned order of every other tool unchanged' do
      expect(tools.pluck('name')).to eq(%w[
                                          search_code_symbols list_capabilities get_project_vision
                                          get_capability_details get_symbol_details list_tickets
                                          get_ticket search_knowledge create_ticket post_comment
                                          list_notifications create_time_session mark_notification_read
                                          update_ticket summarize_time_sessions
                                        ])
    end

    it 'requires project_id and offers no idempotency_key (a read, D6)' do
      schema = tools.last['inputSchema']
      expect(schema['required']).to eq(['project_id'])
      expect(schema['properties'].keys).to include('ticket', 'creator', 'start_date', 'end_date', 'project_id')
      expect(schema['properties']).not_to have_key('idempotency_key')
    end
  end

  it 'reports server version 0.12.0' do
    body = rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'rspec', version: '0' } },
               pat)
    expect(body.dig('result', 'serverInfo', 'version')).to eq('0.12.0')
  end

  context 'when the owner sees all time of the project' do
    before { grant_time(project, view_all: true) }

    it 'sums every booking on the ticket without creator, under scope "all"' do
      answer = report(project_id: project.id, ticket: ticket.id)
      expect(answer['scope']).to eq('all')
      expect(answer.dig('total', 'minutes')).to eq(75)
      expect(answer.dig('total', 'sessions')).to eq(2)
      expect(answer.dig('total', 'hours')).to eq(1.25)
      expect(answer.dig('filters', 'ticket', 'id')).to eq(ticket.id)
    end

    it 'sums only the own bookings with creator "me"' do
      expect(minutes(project_id: project.id, ticket: ticket.id, creator: 'me')).to eq(30)
    end

    it 'sums the whole project without a ticket' do
      expect(minutes(project_id: project.id)).to eq(95)
    end

    it 'answers with the report and nothing else: no single bookings, no citations' do
      result = call(project_id: project.id, ticket: ticket.id)
      expect(result['content'].size).to eq(1)
      expect(result['_meta']).to eq('lalabase/kind' => 'ok')
      expect(result.keys).not_to include('citations', 'structuredContent')
      answer = JSON.parse(result.dig('content', 0, 'text'))
      expect(answer.keys).to contain_exactly('scope', 'filters', 'buckets', 'not_invoiced', 'total')
      expect(answer['buckets'].keys).to contain_exactly('billed', 'in_billing', 'without_billing')
      expect(result.to_json).not_to include('citation', 'duration', 'occurred_on', 'description')
    end

    it 'is open to a read-only token and to a writable one alike' do
      expect(pat).to be_read_only
      expect(minutes(project_id: project.id, ticket: ticket.id)).to eq(75)
      expect(minutes(token: build_pat(read_only: false), project_id: project.id, ticket: ticket.id)).to eq(75)
    end
  end

  context 'when the owner sees only their own time' do
    before { grant_time(project, view_all: false) }

    it 'sums only the own bookings without creator, under scope "own"' do
      answer = report(project_id: project.id, ticket: ticket.id)
      expect(answer['scope']).to eq('own')
      expect(answer.dig('total', 'minutes')).to eq(30)
    end

    it 'sums only the own bookings with creator "me"' do
      expect(minutes(project_id: project.id, ticket: ticket.id, creator: 'me')).to eq(30)
    end

    it "sums a colleague's bookings to zero, never widening the tier" do
      expect(minutes(project_id: project.id, ticket: ticket.id, creator: colleague.id)).to eq(0)
      expect(minutes(project_id: project.id, creator: colleague.id)).to eq(0)
    end

    it 'sums only the own bookings of the whole project without a ticket' do
      expect(minutes(project_id: project.id)).to eq(30)
    end
  end

  context 'without a time permission row' do
    it 'refuses with an error and no numbers' do
      result = call(project_id: project.id, ticket: ticket.id)
      expect(result['isError']).to be(true)
      expect(result['_meta']).to eq('lalabase/code' => 'refused')
      expect_no_numbers(result)
    end

    it 'refuses with the same answer when the row grants no viewing at all' do
      create(:time_session_permission, :no_access, user: user, project: project)
      result = call(project_id: project.id, ticket: ticket.id)
      expect(result['_meta']).to eq('lalabase/code' => 'refused')
      expect_no_numbers(result)
    end
  end

  describe 'the ticket filter' do
    before do
      grant_time(project, view_all: true)
      grant_time(time_only_project, view_all: true)
    end

    it 'answers a ticket of another project like a missing one: empty, no numbers' do
      missing = call(project_id: project.id, ticket: SecureRandom.uuid)
      result = call(project_id: project.id, ticket: other_ticket.id)
      expect(result['isError']).to be_falsey
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
      expect_no_numbers(result)
      expect(result['content'].first['text'].sub(other_ticket.id, 'X'))
        .to eq(missing['content'].first['text'].sub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, 'X'))
    end

    it 'answers a ticket the owner may not read like a missing one, though the time is visible' do
      expect(minutes(project_id: time_only_project.id)).to eq(15)
      result = call(project_id: time_only_project.id, ticket: unreadable_ticket.id)
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
      expect_no_numbers(result)
    end

    # The number is a second road to the same ticket: it must go through the
    # same read scope, or the echoed filter hands out the title (and the
    # minutes) of a ticket the owner may not open.
    it 'answers the number of a ticket the owner may not read like an unknown number' do
      unknown = call(project_id: time_only_project.id, ticket: "##{unreadable_ticket.number + 100}")
      result = call(project_id: time_only_project.id, ticket: "##{unreadable_ticket.number}")
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
      expect_no_numbers(result)
      expect(result.to_json).not_to include(unreadable_ticket.title)
      expect(result['content'].first['text'].sub(/\d+/, 'N')).to eq(unknown['content'].first['text'].sub(/\d+/, 'N'))
    end

    it 'answers an unknown ticket number as empty' do
      result = call(project_id: project.id, ticket: "##{ticket.number + 100}")
      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
    end
  end

  describe 'the project gate' do
    before do
      grant_time(project, view_all: true)
      grant_time(other_project, view_all: true)
    end

    let(:missing) { call(project_id: SecureRandom.uuid) }

    def expect_like_missing(result)
      expect(result).to eq(missing)
      expect(result['_meta']).to eq('lalabase/code' => 'not_found')
      expect_no_numbers(result)
    end

    it 'answers a project outside the token reach like a missing one' do
      narrow = build_pat(project_scopes: { organisation => [other_project] })
      expect(minutes(token: narrow, project_id: other_project.id)).to eq(10)
      expect_like_missing(call(token: narrow, project_id: project.id, ticket: ticket.id))
    end

    it 'answers a project of a foreign organisation like a missing one' do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:time_session, project: foreign_project, organisation: other_organisation, duration: 99)
      end
      expect_like_missing(call(project_id: foreign_project.id))
    end

    it 'answers a project of the organisation the owner has no right in like a missing one' do
      stranger = create(:project, organisation: organisation)
      expect_like_missing(call(project_id: stranger.id))
    end

    it 'refuses a call without project_id as invalid input' do
      result = call(ticket: ticket.id)
      expect(result['isError']).to be(true)
      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
    end

    it 'ignores the org-wide project filter on the project path (D5)' do
      expect(minutes(project_id: project.id, project: other_project.name)).to eq(95)
    end
  end

  # The tool refuses its malformed filters without an error code, so over MCP
  # they read as refused, not invalid_input. Pinned so a client that branches
  # on `_meta` relies on recorded behaviour.
  {
    'a malformed date' => { start_date: '31.08.2026' },
    'a malformed creator' => { creator: 'somebody' },
    'a malformed ticket' => { ticket: 'abc' }
  }.each do |label, arguments|
    it "refuses #{label} without numbers, as the tool reports it (refused)" do
      grant_time(project, view_all: true)
      result = call(project_id: project.id, **arguments)
      expect(result['isError']).to be(true)
      expect(result['_meta']).to eq('lalabase/code' => 'refused')
      expect_no_numbers(result)
    end
  end
end
