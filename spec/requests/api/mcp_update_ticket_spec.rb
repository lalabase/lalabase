# frozen_string_literal: true

require 'rails_helper'

# What: the MCP tool update_ticket over the wire (terminal client S2).
# Type: request spec through /api/mcp, the gates of Mcp::ToolCall included.
# Why: a write from outside the browser. Every way the caller is not allowed to
#   change THIS ticket must write nothing: a read-only token, a project outside
#   the token or the owner's reach, a ticket the owner may not read (answered
#   exactly like a missing one), a ticket that may be read and not written, a
#   ticket of another project or organisation. An account admin passes without a
#   project permission, as in the web. A repeated idempotency key writes once, and
#   a refused call is not pinned to its key.
#
# Security spec: tagged :ci_guard and listed in .github/workflows/guards.yml.
RSpec.describe 'MCP update_ticket: rights, reach and idempotency', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:project) { with_statuses(ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }) }

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Login bricht ab',
                      custom_attributes: { 'status' => 'open', 'priority' => 'high' })
    end
  end

  # The status field the board uses: a single select named "status".
  def with_statuses(target, values = %w[open wip])
    ActsAsTenant.with_tenant(target.organisation) do
      create(:ticket_attribute_definition,
             project: target, name: 'status', field_type: 'select', position: 1,
             labels: { 'de' => 'Status', 'en' => 'Status' },
             options: { 'allowed_values' => values.map { |value| { 'value' => value, 'labels' => { 'de' => value } } } })
    end
    target
  end

  def build_pat(owner, organisations, read_only:, project_scopes: {})
    token = build(:personal_access_token, user: owner, organisations: Array(organisations), read_only: read_only,
                                          project_scopes: project_scopes)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  let(:read_pat) { build_pat(user, organisation, read_only: true) }
  let(:write_pat) { build_pat(user, organisation, read_only: false) }

  def call_tool(pat_record, arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call',
             params: { name: 'update_ticket', arguments: arguments } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{pat_record.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch('result')
  end

  def text_of(result)
    result.dig('content', 0, 'text')
  end

  # Everything a write could leave behind, organisation-wide.
  def written
    ActsAsTenant.without_tenant do
      [TicketBulkRun.count, Activity.count, TicketAssignment.count, Ticket.order(:id).pluck(:title, :custom_attributes)]
    end
  end

  # The whole answer with the address replaced: what a caller can tell apart.
  def seen(result, address)
    result.to_json.gsub(address.to_s, 'ADDRESS')
  end

  it 'changes the status over a writable token' do
    result = call_tool(write_pat, { project_id: project.id, ticket_id: ticket.id, status: 'wip' })

    expect(result['_meta']).to eq('lalabase/kind' => 'ok')
    expect(JSON.parse(text_of(result))).to include('id' => ticket.id, 'status' => 'wip')
    expect(ActsAsTenant.with_tenant(organisation) { ticket.reload.custom_attributes })
      .to eq('status' => 'wip', 'priority' => 'high')
  end

  # One call per example: three requests in one example read as an N+1 to Prosopite.
  changes = { 'status' => { status: 'wip' }, 'title' => { title: 'Neu' }, 'assignees' => { add_assignee_ids: ['me'] } }

  changes.each do |kind, change|
    it "refuses a #{kind} change over a read-only token with read_only and writes nothing" do
      ticket
      before = written
      result = call_tool(read_pat, { project_id: project.id, ticket_id: ticket.id }.merge(change))

      expect(result['isError']).to be true
      expect(result['_meta']).to eq('lalabase/code' => 'read_only')
      expect(written).to eq(before)
    end
  end

  describe 'a project outside the reach' do
    it 'answers a project of another organisation like a missing one' do
      foreign = with_statuses(ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) })
      foreign_ticket = ActsAsTenant.with_tenant(other_organisation) do
        create(:ticket, project: foreign, organisation: other_organisation, creator: create(:user), title: 'Fremd',
                        custom_attributes: { 'status' => 'open' })
      end
      before = written

      result = call_tool(write_pat, { project_id: foreign.id, ticket_id: foreign_ticket.id, status: 'wip' })
      missing = call_tool(write_pat, { project_id: SecureRandom.uuid, ticket_id: foreign_ticket.id, status: 'wip' })

      expect(result['_meta']).to eq('lalabase/code' => 'not_found')
      expect(result).to eq(missing)
      expect(written).to eq(before)
    end

    it 'answers a project the token does not name like a missing one' do
      ticket
      elsewhere = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      narrow_pat = build_pat(user, organisation, read_only: false, project_scopes: { organisation => [elsewhere] })
      before = written

      result = call_tool(narrow_pat, { project_id: project.id, ticket_id: ticket.id, status: 'wip' })

      expect(result['_meta']).to eq('lalabase/code' => 'not_found')
      expect(written).to eq(before)
    end
  end

  # The project is reachable (notes), its tickets are not.
  it 'answers a ticket without read access exactly like a missing one, writing nothing' do
    notes_only = with_statuses(ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) })
    hidden = ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: notes_only, notes_access: :read_only)
      create(:ticket, project: notes_only, organisation: organisation, creator: user, title: 'Vertrauliche Planung',
                      custom_attributes: { 'status' => 'open' })
    end
    missing_id = SecureRandom.uuid
    before = written

    hidden_answer = call_tool(write_pat, { project_id: notes_only.id, ticket_id: hidden.id, status: 'wip' })
    missing_answer = call_tool(write_pat, { project_id: notes_only.id, ticket_id: missing_id, status: 'wip' })

    expect(missing_answer['_meta']).to eq('lalabase/kind' => 'empty')
    expect(seen(hidden_answer, hidden.id)).to eq(seen(missing_answer, missing_id))
    expect(hidden_answer.to_json).not_to include('Vertrauliche Planung')
    expect(written).to eq(before)
  end

  changes.each do |kind, change|
    it "refuses a #{kind} change on a ticket that may be read and not written with forbidden" do
      readable = with_statuses(ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) })
      readable_ticket = ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: readable, tickets_access: :read_only)
        create(:ticket, project: readable, organisation: organisation, creator: user, title: 'Lesbar',
                        custom_attributes: { 'status' => 'open' })
      end
      before = written

      result = call_tool(write_pat, { project_id: readable.id, ticket_id: readable_ticket.id }.merge(change))

      expect(result['isError']).to be true
      expect(result['_meta']).to eq('lalabase/code' => 'forbidden')
      expect(text_of(result)).to eq('Not authorized.')
      expect(written).to eq(before)
    end
  end

  describe 'a ticket id from elsewhere' do
    # The token names this project only; the owner may write the sibling. The
    # lookup through THIS project is what keeps the id of the sibling's ticket
    # out: SaveTicket finds a ticket organisation-wide, so a title would land.
    changes.each do |kind, change|
      it "answers a #{kind} change on a ticket of another project of the same organisation as empty" do
        sibling = with_statuses(ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) })
        sibling_ticket = ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: sibling, tickets_access: :read_write)
          create(:ticket, project: sibling, organisation: organisation, creator: user, title: 'Nebenan',
                          custom_attributes: { 'status' => 'open' })
        end
        narrow_pat = build_pat(user, organisation, read_only: false, project_scopes: { organisation => [project] })
        before = written

        result = call_tool(narrow_pat, { project_id: project.id, ticket_id: sibling_ticket.id }.merge(change))

        expect(result['_meta']).to eq('lalabase/kind' => 'empty')
        expect(text_of(result)).to eq("No ticket found for #{sibling_ticket.id}.")
        expect(written).to eq(before)
      end
    end

    it 'answers a ticket of another organisation as empty' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
      foreign_ticket = ActsAsTenant.with_tenant(other_organisation) do
        create(:ticket, project: foreign, organisation: other_organisation, creator: create(:user), title: 'Fremd')
      end
      project
      before = written

      result = call_tool(write_pat, { project_id: project.id, ticket_id: foreign_ticket.id, title: 'Gekapert' })

      expect(result['_meta']).to eq('lalabase/kind' => 'empty')
      expect(written).to eq(before)
    end
  end

  # Who may be REMOVED reaches beyond the offered people (whoever is on the
  # ticket, every member). It must stop at the organisation: a person of
  # another organisation, assigned and subscribed there, is not removable here.
  it 'refuses to remove a person of another organisation who is on tickets there' do
    stranger = create(:user)
    ActsAsTenant.with_tenant(other_organisation) do
      create(:membership, user: stranger, organisation: other_organisation,
                          role: create(:admin_role, organisation: other_organisation))
      foreign = create(:project, organisation: other_organisation)
      foreign_ticket = create(:ticket, project: foreign, organisation: other_organisation, creator: stranger, title: 'Fremd')
      foreign_ticket.ticket_assignments.create!(user: stranger)
    end
    ticket
    before = written

    result = call_tool(write_pat, { project_id: project.id, ticket_id: ticket.id, remove_assignee_ids: [stranger.id] })

    expect(result['_meta']).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'value_not_allowed')
    expect(result.to_json).not_to include(stranger.first_name.to_s)
    expect(written).to eq(before)
  end

  it 'lets an account admin without a project permission change the status' do
    admin = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
    admin_pat = build_pat(admin, organisation, read_only: false)

    result = call_tool(admin_pat, { project_id: project.id, ticket_id: ticket.id, status: 'wip' })

    expect(result['_meta']).to eq('lalabase/kind' => 'ok')
    expect(ActsAsTenant.with_tenant(organisation) { ticket.reload.custom_attributes['status'] }).to eq('wip')
  end

  describe 'idempotency' do
    let(:args) { { project_id: project.id, ticket_id: ticket.id, status: 'wip', idempotency_key: 'term-1' } }

    it 'writes once for a repeated key and answers the same text' do
      ticket
      first = nil
      replay = nil
      expect do
        first = call_tool(write_pat, args)
        replay = call_tool(write_pat, args)
      end.to change { ActsAsTenant.without_tenant { [TicketBulkRun.count, Activity.count] } }.by([1, 1])

      expect(replay['content']).to eq(first['content'])
      expect([first['_meta'], replay['_meta']]).to all(eq('lalabase/kind' => 'ok'))
    end

    it 'refuses the key with other arguments as invalid_input' do
      call_tool(write_pat, args)
      before = written

      result = call_tool(write_pat, args.merge(status: 'open'))

      expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
      expect(text_of(result)).to match(/already used with different parameters/)
      expect(written).to eq(before)
    end

    # A refused write is not pinned to its key: once the project offers the
    # status, the same call with the same key writes.
    it 'does not store a refused call' do
      refused_args = args.merge(status: 'review', idempotency_key: 'term-2')
      refused = call_tool(write_pat, refused_args)
      expect(refused['_meta']).to eq('lalabase/code' => 'refused', 'lalabase/reason' => 'value_not_allowed')

      ActsAsTenant.with_tenant(organisation) do
        definition = project.ticket_attribute_definitions.find_by!(name: 'status')
        definition.update!(options: { 'allowed_values' => definition.options['allowed_values'] +
                                                            [{ 'value' => 'review', 'labels' => { 'de' => 'review' } }] })
      end
      retried = call_tool(write_pat, refused_args)

      expect(retried['_meta']).to eq('lalabase/kind' => 'ok')
      expect(ActsAsTenant.with_tenant(organisation) { ticket.reload.custom_attributes['status'] }).to eq('review')
    end
  end

  describe 'write provenance (D9)' do
    def audit_lines
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original do |original, message = nil, &block|
        lines << message if message.to_s.start_with?('[MCP write]')
        original.call(message, &block)
      end
      lines
    end

    it 'logs a success with the ticket it addressed' do
      lines = audit_lines
      call_tool(write_pat, { project_id: project.id, ticket_id: ticket.id, status: 'wip' })

      expect(lines).to contain_exactly(
        match(/tool=update_ticket outcome=success token_id=#{write_pat.id} .*project_id=#{project.id} target=#{ticket.id}\z/)
      )
    end

    it 'logs a refused write as denied' do
      readable = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      readable_ticket = ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: readable, tickets_access: :read_only)
        create(:ticket, project: readable, organisation: organisation, creator: user, title: 'Lesbar')
      end
      lines = audit_lines
      call_tool(write_pat, { project_id: readable.id, ticket_id: readable_ticket.id, title: 'Neu' })

      expect(lines).to contain_exactly(match(/tool=update_ticket outcome=denied .*target=#{readable_ticket.id}\z/))
    end
  end
end
