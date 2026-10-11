# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::GetTicket — fetches one ticket as JSON (head, description,
#       posts), addressed either by UUID or by the ticket number users see ("#187").
# Type: Service spec.
# Why:  This is a record-mode tool: it hands back ONE record, so the per-record
#       authorization is the only thing standing between a guessed address and a
#       foreign ticket. Pinned here: (1) requires_actor? is declared, which is what
#       makes the Runner's fail-closed bar apply; (2) a ticket outside the chat's
#       project is "not found", never data — over the number too, which is only
#       unique WITHIN a project; (3) a ticket the user may not read raises instead
#       of serialising, on both addressing paths; (4) a malformed number is refused
#       before any query ("abc".to_i is silently 0); (5) fence-breakout payloads in
#       title, description and post bodies arrive neutralised, including together
#       with the truncation cap.
RSpec.describe Lalabase::Tools::GetTicket do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }

  let(:actor) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project) }
  let(:ticket)  { create(:ticket, project: project, organisation: organisation, creator: actor) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant_tickets(access)
    create(:project_permission, user: actor, project: project, tickets_access: access)
  end

  def run_args(args)
    described_class.execute(args: args, context: context)
  end

  def run(id)
    run_args(ticket_id: id)
  end

  def run_number(value)
    run_args(number: value)
  end

  def payload(id)
    JSON.parse(run(id).content)
  end

  # Counts the statements ActiveRecord actually sends, so "refused without a
  # database hit" is an assertion and not a hope. Schema/transaction/cache rows are
  # bookkeeping, not lookups.
  def sql_during
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      statements << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION CACHE])
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe 'contract metadata' do
    it 'is a read tool, authorizes per record and requires an authenticated user' do
      expect(described_class.mutating?).to be false
      expect(described_class.authorization_mode).to eq(:record)
      expect(described_class.requires_actor?).to be true
    end
  end

  describe 'rights of the asking user' do
    it 'returns the ticket when the user may read it' do
      grant_tickets(:read_write)

      expect(payload(ticket.id)).to include('id' => ticket.id, 'title' => ticket.title)
    end

    # A ticket the user may not read is looked up inside the read scope
    # (Base.readable_tickets) and answers like a missing one: "not authorized"
    # would confirm that the number exists. Both addresses are probed: the
    # number branch must not become a way past the scope. The request spec
    # mcp_ticket_existence_spec holds the whole answer against a missing one.
    it 'answers a ticket the user may not read like a missing one, never its data' do
      result = run(ticket.id)
      expect(result.empty?).to be true
      expect(result.content).to eq("No ticket found for #{ticket.id}.")
    end

    it 'answers the same ticket over its number like a missing one, too' do
      result = run_number(ticket.number)
      expect(result.empty?).to be true
      expect(result.content).to eq("No ticket found for number #{ticket.number}.")
    end

    it 'reports "no ticket" for a ticket in another project, never its data' do
      grant_tickets(:read_write)
      foreign = create(:ticket, project: create(:project, organisation: organisation),
                                organisation: organisation, creator: actor,
                                title: 'Fremdes Projekt Geheimnis')

      result = run(foreign.id)

      expect(result.content).to include('No ticket found')
      expect(result.content).not_to include('Fremdes Projekt Geheimnis')
    end

    it 'reports "no ticket" for a ticket in another organisation' do
      grant_tickets(:read_write)
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        create(:ticket, project: create(:project, organisation: other_org),
                        organisation: other_org, creator: create(:user),
                        title: 'Fremde Organisation Geheimnis')
      end

      result = run(foreign.id)

      expect(result.content).to include('No ticket found')
      expect(result.content).not_to include('Fremde Organisation Geheimnis')
    end
  end

  # The result string IS the MCP wire format (Mcp::ToolCall#result_to_response passes
  # result.content through verbatim), so it stays byte-exact. A ticket description in a
  # developer tool routinely contains a real code fence; rewriting it would hand an MCP
  # client bytes it cannot turn back. The fence guard for OUR model loop sits on the
  # channel instead (Runner#tool_result_message, pinned in runner_spec).
  describe 'payload fidelity (the string is also the MCP wire format)' do
    before { grant_tickets(:read_write) }

    it 'returns code fences in description and post bodies byte-exact' do
      fenced = create(:ticket, project: project, organisation: organisation, creator: actor,
                               title: 'Repro ```ruby```',
                               content: "Fehler in\n```ruby\nputs 1\n```")
      create(:post, ticket: fenced, organisation: organisation, user: actor,
                    content: "Fix:\n```diff\n- a\n+ b\n```")

      raw = run(fenced.id).content

      expect(raw).to include('```ruby')
      expect(raw).to include('```diff')
      expect(payload(fenced.id)['title']).to eq('Repro ```ruby```')
    end

    it 'still caps a long body and keeps the truncation marker' do
      capped = create(:ticket, project: project, organisation: organisation, creator: actor,
                               content: 'a' * (described_class::MAX_BODY_CHARS + 500))

      body = payload(capped.id)['description_text']

      expect(body).to end_with(described_class::TRUNCATION_MARKER)
      expect(body.length).to eq(described_class::MAX_BODY_CHARS + described_class::TRUNCATION_MARKER.length)
    end
  end

  # The citation is the rights gate for everyone EXCEPT the asker: without an area the
  # answer counts as content-free and every reader of the shared chat sees the ticket.
  describe 'citations (the gate for other readers of the shared chat)' do
    it 'cites the fetched ticket with the tickets area' do
      grant_tickets(:read_write)

      cites = run(ticket.id).citations

      expect(cites.map { |c| c[:id] }).to eq([ticket.id])
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:tickets])
    end

    it 'cites nothing when no ticket was found' do
      grant_tickets(:read_write)
      foreign = create(:ticket, project: create(:project, organisation: organisation),
                                organisation: organisation, creator: actor)

      expect(run(foreign.id).citations).to be_empty
    end
  end

  # S0: users know the number that stands in the UI ("#187"), not the UUID. Parsing is
  # tolerant, validation is strict — the two halves are tested separately below.
  describe 'addressing a ticket by its number' do
    before { grant_tickets(:read_write) }

    def number_payload(value)
      JSON.parse(run_number(value).content)
    end

    it 'returns the same payload as the UUID does' do
      by_number = number_payload(ticket.number)
      by_uuid   = payload(ticket.id)

      expect(by_number).to eq(by_uuid)
      expect(by_number).to include('id' => ticket.id, 'number' => ticket.number)
    end

    # One example per spelling rather than one loop: repeating the identical lookup
    # inside a single example is what Prosopite is built to flag, and the point here
    # is the parse, not the query count.
    {
      'the bare integer' => ->(t) { t.number },
      'the number as a string' => ->(t) { t.number.to_s },
      'the "#187" spelling users say' => ->(t) { "##{t.number}" },
      'stray blanks around it' => ->(t) { " # #{t.number} " }
    }.each do |label, spelling|
      it "accepts #{label}" do
        expect(number_payload(spelling.call(ticket))['id']).to eq(ticket.id)
      end
    end

    it 'cites the ticket with the tickets area, exactly as the UUID path does' do
      cites = run_number(ticket.number).citations

      expect(cites.map { |c| c[:id] }).to eq([ticket.id])
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:tickets])
    end

    it 'reports an unknown number as empty, not as an error' do
      result = run_number(ticket.number + 999)

      expect(result.success?).to be true
      expect(result.kind).to eq(:empty)
      expect(result.content).to include('No ticket found for number')
      expect(result.citations).to be_empty
    end

    # THE scoping example: numbers restart per project, so the same "#1" exists many
    # times in one organisation. Only the chat's own project may answer.
    it 'does not reach the same number in a sibling project of the same organisation' do
      sibling = create(:project, organisation: organisation)
      create(:project_permission, user: actor, project: sibling, tickets_access: :read_write)
      foreign = create(:ticket, project: sibling, organisation: organisation, creator: actor,
                                title: 'Nachbarprojekt Geheimnis')
      # Same number, different project — the row exists, it is simply out of scope.
      expect(foreign.number).to eq(ticket.number)

      result = run_number(foreign.number)

      expect(result.content).not_to include('Nachbarprojekt Geheimnis')
      expect(JSON.parse(result.content)['id']).to eq(ticket.id)
    end
  end

  # "abc".to_i is silently 0. Without the strict half of the contract each of these
  # would send a lookup for ticket number 0 and answer "no ticket found" — a wrong
  # answer with database authority instead of a refused argument.
  describe 'a malformed number is refused before any query' do
    before do
      grant_tickets(:read_write)
      ticket # force the fixtures, so the measured block only carries the tool's own SQL
      context
    end

    %w[abc 0 -1 1.5 187abc #].each do |value|
      it "refuses #{value.inspect} without hitting the database" do
        result = nil
        statements = sql_during { result = run_number(value) }

        expect(result.success?).to be false
        expect(result.error).to match(/number/)
        expect(statements).to be_empty
      end
    end

    it 'refuses the integer zero and a negative integer too' do
      expect(run_number(0).success?).to be false
      expect(run_number(-5).success?).to be false
    end
  end

  describe 'ticket_id wins when both addresses are given' do
    before { grant_tickets(:read_write) }

    it 'serves the ticket_id and ignores the number' do
      other = create(:ticket, project: project, organisation: organisation, creator: actor,
                              title: 'Ueber die Nummer adressiert')

      result = run_args(ticket_id: ticket.id, number: other.number)

      expect(JSON.parse(result.content)['id']).to eq(ticket.id)
    end

    it 'still refuses a malformed ticket_id instead of falling through to the number' do
      result = run_args(ticket_id: 'not-a-uuid', number: ticket.number)

      expect(result.success?).to be false
      expect(result.error).to eq('invalid ticket_id format')
    end
  end

  # §9.2: an ambiguous number answers with candidates, not with an error, so the model
  # can ask a question the user answers with one click. Within ONE project the number is
  # unique, so the branch cannot fire through the normal scope — the scope is widened
  # here on purpose. Under test is the ambiguity branch; the project scoping has its own
  # example above and must not be read out of these.
  describe 'an ambiguous number (built for the org-wide scope of S3)' do
    let(:sibling) { create(:project, organisation: organisation) }
    let(:twin) do
      create(:ticket, project: sibling, organisation: organisation, creator: actor,
                      title: 'Zwilling im Nachbarprojekt')
    end

    def widen_scope_to(*tickets)
      allow(described_class).to receive(:base_scope)
        .and_return(Ticket.where(id: tickets.map(&:id)).includes(:creator, :assignees, :project))
    end

    def grant_sibling(access)
      create(:project_permission, user: actor, project: sibling, tickets_access: access)
    end

    it 'answers with the candidates instead of an error' do
      grant_tickets(:read_write)
      grant_sibling(:read_write)
      widen_scope_to(ticket, twin)

      result = run_number(ticket.number)
      body = JSON.parse(result.content)

      expect(result.success?).to be true
      expect(result.kind).to eq(:ok)
      expect(body['ambiguous']).to be true
      expect(body['number']).to eq(ticket.number)
      expect(body['candidates'].map { |c| c['id'] }).to contain_exactly(ticket.id, twin.id)
      expect(body['candidates'].map { |c| c.dig('project', 'name') })
        .to contain_exactly(project.name, sibling.name)
    end

    # Candidate titles are content. Without a cited area the list would reach every
    # reader of a shared chat ungated — the PR #534 failure mode.
    it 'cites every listed candidate with the tickets area' do
      grant_tickets(:read_write)
      grant_sibling(:read_write)
      widen_scope_to(ticket, twin)

      cites = run_number(ticket.number).citations

      expect(cites.map { |c| c[:id] }).to contain_exactly(ticket.id, twin.id)
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:tickets])
    end

    it 'drops a candidate the user may not read and serves the single survivor in full' do
      grant_tickets(:read_write)
      twin # created without any permission on the sibling project
      widen_scope_to(ticket, twin)

      result = run_number(ticket.number)
      body = JSON.parse(result.content)

      expect(result.content).not_to include('Zwilling im Nachbarprojekt')
      expect(body['ambiguous']).to be_nil
      expect(body['id']).to eq(ticket.id)
    end

    it 'reports empty when the user may read none of the candidates' do
      # No permission on either project — nothing to serve, nothing to leak.
      widen_scope_to(ticket, twin)

      result = run_number(ticket.number)

      expect(result.kind).to eq(:empty)
      expect(result.content).not_to include('Zwilling im Nachbarprojekt')
      expect(result.citations).to be_empty
    end

    it 'caps the candidate list and reports the true total' do
      grant_tickets(:read_write)
      grant_sibling(:read_write)
      stub_const('Lalabase::Tools::GetTicket::MAX_CANDIDATES', 1)
      widen_scope_to(ticket, twin)

      body = JSON.parse(run_number(ticket.number).content)

      expect(body['candidates'].size).to eq(1)
      expect(body['candidates_total']).to eq(2)
    end
  end

  describe 'the advertised schema (an external MCP contract)' do
    let(:schema) { described_class.input_schema }

    it 'offers both addresses and requires neither, so an old UUID-only client keeps working' do
      # :project joined in S3a T5. Additive like the two addresses before it: the
      # MCP surface fixes the project through its mandatory project_id, and a call
      # that passes the filter there is REFUSED rather than silently ignored -- so
      # no existing client changes behaviour by this key appearing.
      # The paging and full-text keys joined in S1 b, optional and additive the same
      # way: without them the answer is the one an old client knows.
      expect(schema[:properties].keys).to contain_exactly(:ticket_id, :number, :project, :posts_page, :posts_per_page,
                                                          :posts_order, :attachments_page, :full_text, :post_id)
      expect(schema[:required]).to eq([])
    end

    # Not a ['integer','string'] union: GoogleVertexProvider#gemini_function_declaration
    # hands this schema to Gemini verbatim, and its OpenAPI subset takes one type per
    # property. The tolerant parse covers a model that sends the bare integer anyway.
    it 'declares the number as a single-typed string' do
      expect(schema.dig(:properties, :number, :type)).to eq('string')
    end

    it 'names the number in the description, so the model knows it is addressable' do
      expect(described_class.description).to match(/number/i)
    end
  end

  describe 'guards that predate the chat unlock' do
    before { grant_tickets(:read_write) }

    it 'rejects a non-UUID ticket_id instead of crashing on the uuid column' do
      result = run('not-a-uuid')

      expect(result.success?).to be false
      expect(result.error).to eq('invalid ticket_id format')
    end

    it 'requires an address: neither a ticket_id nor a number is a clean error' do
      expect(run_args({}).error).to eq('ticket_id or number is required')
      expect(run_args(ticket_id: '', number: '  ').error).to eq('ticket_id or number is required')
    end

    it 'errors without a project context' do
      result = described_class.execute(
        args: { ticket_id: ticket.id },
        context: Lalabase::Tools::Context.new(actor: actor, organisation: organisation)
      )

      expect(result.success?).to be false
      expect(result.error).to eq('project context missing')
    end
  end

  # S3a T3 (Plan §9.1): the org-wide reach makes the §9.2 candidate path REAL —
  # no stubbed base_scope here, the context's Scope decides which projects the
  # number is resolved in. Auto-numbering starts at 1 per project, so the first
  # ticket of each project collides by construction.
  describe 'org-wide reach (S3a T3)' do
    let(:reachable)  { create(:project, organisation: organisation) }
    let(:reachable2) { create(:project, organisation: organisation) }
    let(:forbidden)  { create(:project, organisation: organisation) }

    let(:org_context) do
      Lalabase::Tools::Context.new(
        actor: actor, organisation: organisation, project: nil,
        scope: Lalabase::Tools::Scope.new(organisation: organisation, actor: actor)
      )
    end

    let!(:first_ticket) do
      create(:ticket, project: reachable, organisation: organisation, creator: actor, title: 'Erster')
    end
    let!(:twin_ticket) do
      create(:ticket, project: reachable2, organisation: organisation, creator: actor, title: 'Zwilling')
    end
    let!(:foreign_twin) do
      create(:ticket, project: forbidden, organisation: organisation, creator: actor, title: 'Geheimes Ticket')
    end

    before { create(:project_permission, user: actor, project: reachable, tickets_access: 'read_only') }

    def org_run(args)
      described_class.execute(args: args, context: org_context)
    end

    # ⚠️ THE state E3 made routine (Bezugs-Sammlung §2.2, Review zu #642). Chip on
    # one project, reference on a ticket in ANOTHER: since S2 nobody has to do
    # anything unusual to get there, because setting a reference no longer moves
    # the chip. The prompt then names that ticket by title as the SUBJECT of the
    # conversation while the search reach is confined elsewhere -- so a lookup by
    # its uuid came back empty and the model, holding the title, answered from the
    # title alone. A plausible answer about a ticket nothing ever read.
    #
    # The rule this pins: what the thread POINTS AT may be read; where it SEARCHES
    # stays the chip's business. Rights are unaffected -- the reference passed
    # Tools::Scope#resolve_reference when it was stored and #serve still authorizes
    # per record.
    describe 'a reference outside the chip (Bezugs-Sammlung E3)' do
      # Chip on `reachable`, so `reachable2` is out of the searched set even though
      # the actor may read it.
      let(:scoped_context) do
        Lalabase::Tools::Context.new(
          actor: actor, organisation: organisation, project: nil,
          scope: Lalabase::Tools::Scope.new(
            organisation: organisation, actor: actor, only_project_id: reachable.id,
            references: [{ 'type' => 'Ticket', 'id' => twin_ticket.id }]
          )
        )
      end

      before { create(:project_permission, user: actor, project: reachable2, tickets_access: 'read_only') }

      it 'serves the referenced ticket by id, even though the chip points elsewhere' do
        result = described_class.execute(args: { ticket_id: twin_ticket.id }, context: scoped_context)

        expect(JSON.parse(result.content)['id']).to eq(twin_ticket.id)
      end

      # THE anchor, and without it the cell above is satisfied by simply dropping
      # the chip: a ticket in the same out-of-reach project that is NOT referenced
      # stays out of reach. The widening is about the named objects, not about the
      # project they happen to live in.
      it 'still refuses an unreferenced ticket in the same project' do
        sibling = create(:ticket, project: reachable2, organisation: organisation, creator: actor,
                                  title: 'Nicht referenziert')

        result = described_class.execute(args: { ticket_id: sibling.id }, context: scoped_context)

        expect(result.content).to include('No ticket found')
      end

      # ...and the widening does NOT reach the NUMBER path. A number is not an
      # identity (it is unique per project only), so resolving one through the
      # references would answer "which #1 did you mean" with an object the search
      # was never allowed to see.
      it 'does not widen the number path' do
        result = described_class.execute(args: { number: twin_ticket.number.to_s }, context: scoped_context)

        expect(JSON.parse(result.content)['id']).to eq(first_ticket.id)
      end

      # ⚠️ THE case the position-based flag missed (review of #642, A2). The model
      # may narrow a call itself with the `project` filter, and that branch of
      # Base.coverage_for never asks Scope#coverage at all -- it builds
      # `chosen: <project>` by hand. by_id still falls through to the reference,
      # so the answer read from somewhere else while the line said "Durchsucht:
      # nur A". Both halves of the mechanism failed in ONE call.
      #
      # Hence the flag is set from the READ, by the only place that knows the
      # fallback was used, and it replaces the `chosen` sentence rather than
      # decorating it: the call did not stay in the chosen project, so it must not
      # wear its name.
      it 'carries outside when the reference was read despite a project filter' do
        result = described_class.execute(
          args: { ticket_id: twin_ticket.id, project: reachable.name }, context: scoped_context
        )

        expect(JSON.parse(result.content)['id']).to eq(twin_ticket.id)
        expect(result.coverage).to include(outside: true)
        expect(result.coverage).not_to include(chosen: reachable.name)
      end

      # The negative half. "Sets the flag" is true of an implementation that sets
      # it always, and then every answer would carry a sentence about a reference
      # that was never reached for.
      it 'carries no outside when nothing was read from beyond the reach' do
        result = described_class.execute(args: { ticket_id: first_ticket.id }, context: scoped_context)

        expect(result.coverage).not_to include(outside: true)
      end

      # Rights are NOT widened. The reference was authorized when it was stored;
      # if the actor has lost the area since, the record policy still refuses --
      # and it refuses by raising, not by serving.
      it 'does not serve a referenced ticket the actor may no longer read' do
        ProjectPermission.find_by(user: actor, project: reachable2).destroy!

        result = described_class.execute(args: { ticket_id: twin_ticket.id }, context: scoped_context)

        expect(result.content).to include('No ticket found')
      end
    end

    it 'serves a number that is unambiguous within the reachable projects' do
      result = org_run(number: first_ticket.number.to_s)

      expect(JSON.parse(result.content)['id']).to eq(first_ticket.id)
    end

    it 'answers an ambiguous number with candidates carrying each project (§9.2)' do
      create(:project_permission, user: actor, project: reachable2, tickets_access: 'read_only')

      body = JSON.parse(org_run(number: first_ticket.number.to_s).content)

      expect(body['ambiguous']).to be true
      expect(body['candidates'].map { |c| c['id'] }).to contain_exactly(first_ticket.id, twin_ticket.id)
    end

    it 'never surfaces a same-numbered ticket from a no-access project (§12-S3a)' do
      result = org_run(number: foreign_twin.number.to_s)

      expect(JSON.parse(result.content)['id']).to eq(first_ticket.id)
      expect(result.content).not_to include('Geheimes Ticket')
    end

    it 'treats the UUID of a no-access ticket as not found, not as a leak (§12-S3a)' do
      result = org_run(ticket_id: foreign_twin.id)

      expect(result.kind).to eq(:empty)
      expect(result.content).not_to include('Geheimes Ticket')
    end

    it 'reports the coverage of its answer (L7 contract field)' do
      expect(org_run(number: first_ticket.number.to_s).coverage).to eq(searched: 1, total: 3)
    end

    # The coverage is set centrally in execute "so no branch can forget it" —
    # these two pin the branches a hit-only assertion would leave unwatched.
    it 'wears the coverage on the candidate answer too' do
      create(:project_permission, user: actor, project: reachable2, tickets_access: 'read_only')

      expect(org_run(number: first_ticket.number.to_s).coverage).to eq(searched: 2, total: 3)
    end

    it 'wears the coverage on a miss too' do
      result = org_run(number: '999')

      expect(result.kind).to eq(:empty)
      expect(result.coverage).to eq(searched: 1, total: 3)
    end
  end
  # The reason this tool exists at all for a referenced ticket: the system prompt
  # names the ticket but never its content (Bezugs-Sammlung E5), so whatever the
  # model is going to know about the attached PDF, it learns HERE. Without these
  # keys it could not even tell that a file was attached.
  describe 'attachments of the ticket' do
    before { grant_tickets(:read_write) }

    def attach(trait, **attrs)
      create(:ticket_document, trait, ticket: ticket, organisation: organisation, **attrs)
    end

    it 'carries the attachment list with the extracted text' do
      attach(:with_pdf, plain_text_version: 'Angebot: 4.200 Euro netto')

      files = payload(ticket.id)['attachments']

      expect(files.size).to eq(1)
      expect(files.first['filename']).to eq('test_document.pdf')
      expect(files.first['text']).to eq('Angebot: 4.200 Euro netto')
      expect(files.first['text_status']).to eq('available')
    end

    it 'reports an empty list rather than omitting the key' do
      expect(payload(ticket.id)['attachments']).to eq([])
      expect(payload(ticket.id)['attachments_total']).to eq(0)
      expect(payload(ticket.id)['attachments_truncated']).to be(false)
    end

    # Same bound as the bodies, one size down: an attachment is context for the
    # ticket, not the ticket. Ten of them at the body cap would eat a third of the
    # run's whole tool budget (Runner::DEFAULT_MAX_TOOL_RESULT_CHARS) in one call.
    it 'caps a long attachment text and keeps the truncation marker' do
      attach(:with_pdf, plain_text_version: 'a' * (described_class::MAX_ATTACHMENT_TEXT_CHARS + 500))

      text = payload(ticket.id)['attachments'].first['text']

      expect(text).to end_with(described_class::TRUNCATION_MARKER)
      expect(text.length).to eq(described_class::MAX_ATTACHMENT_TEXT_CHARS + described_class::TRUNCATION_MARKER.length)
    end

    it 'leaves a text of exactly the cap alone' do
      attach(:with_pdf, plain_text_version: 'a' * described_class::MAX_ATTACHMENT_TEXT_CHARS)

      text = payload(ticket.id)['attachments'].first['text']

      expect(text).not_to include(described_class::TRUNCATION_MARKER)
      expect(text.length).to eq(described_class::MAX_ATTACHMENT_TEXT_CHARS)
    end

    # Paused for the SETUP only: every ticket_document create touches its ticket and
    # attaches its own blob, which prosopite reads as an N+1 of the factory. The block
    # form restores the previous state even if a create raises. The read path below
    # stays under watch — twelve attachments are exactly the size at which a missing
    # preload would show.
    def attach_many(count)
      Prosopite.pause do
        base = 1.hour.ago
        count.times do |i|
          attach(:with_pdf, plain_text_version: "file-#{i}", created_at: base + i.minutes)
        end
      end
    end

    it 'bounds the number of attachments and says that it did' do
      attach_many(described_class::MAX_ATTACHMENTS + 2)

      body = payload(ticket.id)

      expect(body['attachments'].size).to eq(described_class::MAX_ATTACHMENTS)
      expect(body['attachments_total']).to eq(described_class::MAX_ATTACHMENTS + 2)
      expect(body['attachments_truncated']).to be(true)
    end

    # Which files survive the bound is not a detail: it decides what the model reads.
    # Oldest first, like the posts.
    it 'keeps the oldest attachments when it cuts' do
      attach_many(described_class::MAX_ATTACHMENTS + 2)

      texts = payload(ticket.id)['attachments'].map { |file| file['text'] }

      expect(texts).to eq(Array.new(described_class::MAX_ATTACHMENTS) { |i| "file-#{i}" })
    end

    # n and n-1, because `>` and `>=` are one character apart and only the boundary
    # tells them apart: at exactly the cap nothing was cut, and saying otherwise sends
    # the model looking for files that are all already in front of it.
    it 'reports exactly the cap as complete, not as truncated' do
      attach_many(described_class::MAX_ATTACHMENTS)

      body = payload(ticket.id)

      expect(body['attachments'].size).to eq(described_class::MAX_ATTACHMENTS)
      expect(body['attachments_total']).to eq(described_class::MAX_ATTACHMENTS)
      expect(body['attachments_truncated']).to be(false)
    end

    it 'leaves a list below the cap untouched' do
      attach_many(described_class::MAX_ATTACHMENTS - 1)

      body = payload(ticket.id)

      expect(body['attachments'].size).to eq(described_class::MAX_ATTACHMENTS - 1)
      expect(body['attachments_truncated']).to be(false)
    end

    # The status the model needs most often, because the extraction job runs
    # perform_later: a file uploaded a moment ago has no text YET, which is not the
    # same as a file that has none.
    it 'distinguishes a file not read yet from one with nothing in it' do
      attach(:with_pdf, plain_text_version: nil)
      attach(:with_png, plain_text_version: nil)
      attach(:with_pdf, plain_text_version: '')

      statuses = payload(ticket.id)['attachments'].map { |file| file['text_status'] }

      expect(statuses).to contain_exactly('unavailable', 'unsupported', 'empty')
    end

    # A download URL stays out, exactly as the header promises for the rest of the
    # payload: the model gets the CONTENT, the browser gets the file. Asserted on the
    # keys, not on a substring search of the whole payload — a relative path would
    # slip through "does it contain http".
    it 'never carries a download url' do
      attach(:with_pdf, plain_text_version: 'x')

      expect(payload(ticket.id)['attachments'].first.keys)
        .to contain_exactly('id', 'filename', 'content_type', 'byte_size', 'text', 'text_status')
      expect(run(ticket.id).content).not_to include('http')
    end
  end
end
