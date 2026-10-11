# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::Scope — the org-wide reach of one assistant tool call
#       (Plan doc/persoenlicher_assistent_plan.md §9.1, S3a T3): which projects
#       the asker may read for a given area, plus the coverage numbers (L7) the
#       answer must disclose.
# Type: Service spec.
# Why:  This object is the ONE rights path for org-wide tools. If it widens, a
#       tool sums foreign projects into a database-backed answer; if it narrows
#       silently, "0 unabgerechnete Stunden" carries database authority for a
#       fraction of the organisation without saying so (L7).
RSpec.describe Lalabase::Tools::Scope do
  let(:organisation) { create(:organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }
  let!(:allowed)     { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:forbidden)   { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:actor) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def scope
    described_class.new(organisation: organisation, actor: actor)
  end

  describe '#project_ids' do
    it 'returns only the projects whose area the actor may read' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      expect(scope.project_ids(area: :tickets)).to contain_exactly(allowed.id)
    end

    it 'is empty without an actor (fail-closed)' do
      empty = described_class.new(organisation: organisation, actor: nil)
      expect(empty.project_ids(area: :tickets)).to eq([])
    end

    it 'keeps areas apart: notes access does not open tickets' do
      create(:project_permission, user: actor, project: allowed, notes_access: 'read_only')
      expect(scope.project_ids(area: :tickets)).to eq([])
      expect(scope.project_ids(area: :notes)).to contain_exactly(allowed.id)
    end
  end

  describe '#coverage (L7)' do
    it 'reports searched vs. total projects of the organisation' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      expect(scope.coverage(area: :tickets)).to eq(searched: 1, total: 2)
    end

    it 'reports zero searched when the actor may read nothing (fail-closed)' do
      expect(scope.coverage(area: :tickets)).to eq(searched: 0, total: 2)
    end
  end

  # The two rules that live HERE and nowhere else (T3 second review): the org
  # paths used to take raw accessible_project_ids, which neither checks the
  # membership nor knows about archived projects.
  describe 'membership and archive rules' do
    it 'gives an inactive member nothing, permission rows or not' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      actor.memberships.find_by(organisation: organisation).update!(active: false)

      expect(scope.project_ids(area: :tickets)).to eq([])
    end

    it 'leaves archived projects out of the reach AND out of the total' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      create(:project_permission, user: actor, project: forbidden, tickets_access: 'read_only')
      forbidden.update!(archived_at: Time.current)

      expect(scope.project_ids(area: :tickets)).to contain_exactly(allowed.id)
      expect(scope.coverage(area: :tickets)).to eq(searched: 1, total: 1)
    end

    it 'gives an account admin every active project without permission rows' do
      admin_role = create(:role, organisation: organisation, title: 'account_admin')
      actor.memberships.find_by(organisation: organisation).update!(role: admin_role)

      expect(scope.project_ids(area: :tickets)).to contain_exactly(allowed.id, forbidden.id)
    end
  end
  # Bezugs-Sammlung S1 (§6): the reference collection. Same design as the project
  # chip one level down: a STORED entry is never the answer, it is a question
  # asked again at read time against the asker's current reach.
  describe 'the reference collection (S1)' do
    let(:ticket) { create(:ticket, project: allowed, organisation: organisation) }

    def entry(type, id)
      Assistant::ReferenceRegistry.stored_entry(type: type, id: id)
    end

    def scope_with_ticket(id)
      described_class.new(organisation: organisation, actor: actor, references: [entry('Ticket', id)])
    end

    # The resolved collection's first entry. S1 stores at most one, so every
    # example that used to ask the old #ticket_selection asks this.
    def resolved(scope)
      scope.references.first
    end

    context 'when the ticket is within reach' do
      before { create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only') }

      it 'resolves the reference' do
        expect(resolved(scope_with_ticket(ticket.id))).to eq(ticket)
      end

      # T-5 (plan §12), THE mutation probe for E3, and the sentence this cut
      # exists to make true: a reference names the SUBJECT of the conversation,
      # it does not narrow the REACH. Until S2 it did both, and that was
      # definable only while a thread held at most one entry -- two references
      # from two projects have no project, and `references.first` would have
      # narrowed to whichever was set first while the chip named the last.
      #
      # ⚠️ The positive anchor is load-bearing. Without "the reference still
      # resolves", a Scope that resolved nothing at all would satisfy the reach
      # assertion, and so would one whose actor is nil.
      it 'leaves the reach alone: a reference is a subject, not a narrowing' do
        create(:project_permission, user: actor, project: forbidden, tickets_access: 'read_only')
        narrowed = scope_with_ticket(ticket.id)

        expect(resolved(narrowed)).to eq(ticket)
        expect(narrowed.project_ids(area: :tickets)).to contain_exactly(allowed.id, forbidden.id)
        expect(narrowed.project_ids(area: :tickets)).to eq(scope.project_ids(area: :tickets))
      end

      # And in every OTHER area too, which is where the old coupling bit hardest:
      # a reference to a ticket silently pinned the note and time lookups to that
      # ticket's project as well.
      it 'leaves every other area alone too' do
        # The row for `allowed` already exists (the before block), and a
        # ProjectPermission is unique per user and project.
        ProjectPermission.find_by(user: actor, project: allowed).update!(notes_access: 'read_only')
        create(:project_permission, user: actor, project: forbidden, notes_access: 'read_only')

        expect(scope_with_ticket(ticket.id).project_ids(area: :notes))
          .to contain_exactly(allowed.id, forbidden.id)
      end
    end

    # The whole point of resolving instead of trusting the column. Each of these
    # is a way a stored id stops meaning what it meant when it was stored.
    context 'when the ticket is out of reach' do
      it 'ignores a ticket in a project the actor may not read' do
        expect(resolved(scope_with_ticket(ticket.id))).to be_nil
      end

      it 'ignores a ticket in an ARCHIVED project' do
        create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
        allowed.update!(archived_at: Time.current)

        expect(resolved(scope_with_ticket(ticket.id))).to be_nil
      end

      it 'ignores a ticket of another organisation' do
        other = create(:organisation)
        foreign = ActsAsTenant.with_tenant(other) do
          create(:ticket, project: create(:project, organisation: other), organisation: other,
                          creator: create(:user))
        end

        expect(resolved(scope_with_ticket(foreign.id))).to be_nil
      end

      it 'ignores an id that names nothing at all' do
        expect(resolved(scope_with_ticket(SecureRandom.uuid))).to be_nil
      end

      # No refusal that NAMES the ticket. A name is exactly what the app withholds
      # from someone without access, so an unresolvable reference must leave no
      # trace in what the answer discloses.
      #
      # ⚠️ Since E3 the REACH half of this says nothing on its own -- no reference
      # narrows any more, resolvable or not. What still bites is the coverage: a
      # `chosen:` key would name a project, and the only project this thread could
      # name is the one holding a ticket the asker may not read.
      it 'names nothing in the coverage, and leaves the reach where it was' do
        create(:project_permission, user: actor, project: forbidden, tickets_access: 'read_only')

        narrowed = scope_with_ticket(ticket.id)

        expect(resolved(narrowed)).to be_nil
        expect(narrowed.project_ids(area: :tickets)).to contain_exactly(forbidden.id)
        expect(narrowed.coverage(area: :tickets)).to eq(searched: 1, total: 2)
      end
    end

    # Since E3 there is exactly ONE narrowing left, the chip. This block used to
    # pin how two of them combined; what it pins now is that they are INDEPENDENT
    # -- the chip still narrows with a reference standing, and the reference still
    # resolves inside a reach the chip has cut down. That is the whole shape of
    # the decoupling, in two examples.
    context 'when chip and reference are both set' do
      before do
        create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
        create(:project_permission, user: actor, project: forbidden, tickets_access: 'read_only')
      end

      def scope_with_both(project_id:, ticket_id:)
        described_class.new(organisation: organisation, actor: actor,
                            only_project_id: project_id, references: [entry('Ticket', ticket_id)])
      end

      # The chip is the narrowing, and it still is one when a reference stands
      # beside it. The anchor for the cell below: without it, a Scope that had
      # stopped honouring the chip altogether would pass that one too.
      it 'still honours the chip, which is now the only narrowing' do
        narrowed = scope_with_both(project_id: allowed.id, ticket_id: ticket.id)

        expect(narrowed.project_ids(area: :tickets)).to contain_exactly(allowed.id)
      end

      # ⚠️ THE cell of E3, and it used to assert the opposite. Reference in one
      # project, chip on another: before this cut that was two narrowings
      # excluding each other, and the honest answer was an EMPTY reach -- an
      # unanswerable thread the user could reach by clicking two buttons that both
      # looked reasonable. Now they are two different questions: the chip says
      # where to look, the reference says what we are talking about, and asking
      # about a ticket while searching elsewhere is a perfectly ordinary thing to
      # do ("was steht im alten CMS zu diesem Fehler?").
      it 'searches where the chip says while the reference names a ticket elsewhere' do
        elsewhere = create(:ticket, project: forbidden, organisation: organisation)
        narrowed = scope_with_both(project_id: allowed.id, ticket_id: elsewhere.id)

        expect(resolved(narrowed)).to eq(elsewhere)
        expect(narrowed.selection).to eq(allowed)
        expect(narrowed.project_ids(area: :tickets)).to contain_exactly(allowed.id)
        # ...and the coverage names the CHIP's project, the only narrowing there is.
        #
        # ⚠️ NOT `outside: true` here, and that correction is the point. A first
        # attempt derived the flag from where the references SIT, which answers the
        # wrong question: whether something beyond the reach was actually read is
        # known only by the call that read it (GetTicket.by_id). Derived here it
        # also fired across areas, where a ticket's project is legitimately absent
        # from the documents reach.
        expect(narrowed.coverage(area: :tickets)).to eq(searched: 1, total: 2, chosen: allowed.name)
      end
    end

    # The reference costs an extra resolution of the asker's reach, and that
    # resolution is not a lookup: active_member?, the admin short circuit, the
    # global-permission check and a pluck. The reference resolution asks for its
    # type's area and resolve_project_ids asks again for it, so the area the reference
    # lives in was being paid for twice, on a path the job walks up to three
    # times per answer.
    #
    # The reach assertion is not decoration: resolve_project_ids returns early on
    # a nil actor, and without it a version that never reached the call at all
    # would satisfy the count.
    it 'resolves the asker\'s reach once per area, reference or not' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      allow(AccessCheck::ProjectAccessService).to receive(:accessible_project_ids).and_call_original

      narrowed = scope_with_ticket(ticket.id)

      expect(narrowed.project_ids(area: :tickets)).to contain_exactly(allowed.id)
      expect(AccessCheck::ProjectAccessService).to have_received(:accessible_project_ids)
        .with(actor, organisation, action: :read, area: :tickets).once
    end

    # L7 honesty, turned around by E3: the reference is NOT a narrowing any more,
    # so the coverage must not name its project. Naming one would tell the reader
    # the answer was confined to it while the search ran across everything they
    # may read -- the same lie the old coupling told, only from the other side.
    #
    # ⚠️ The `searched` number is the anchor: it says the reach really is the full
    # two projects, so this cannot pass by having no reach at all.
    it 'names no project in the coverage, because the reference narrows nothing' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      create(:project_permission, user: actor, project: forbidden, tickets_access: 'read_only')

      expect(scope_with_ticket(ticket.id).coverage(area: :tickets)).to eq(searched: 2, total: 2)
    end

    # ⚠️ `outside` REPLACES the named sentence rather than decorating it (review of
    # #642). A call that fell back to the reference did not stay inside the chosen
    # project, so wearing its name would be exactly the lie the flag exists to
    # prevent. Decided here rather than at the call site, so the shape of a coverage
    # hash keeps one owner.
    #
    # Who SETS it is the reader (GetTicket.by_id), not this class: only the call
    # that actually reached beyond the reach knows that it did.
    it 'drops the chosen project when the answer read from outside it' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      create(:project_permission, user: actor, project: forbidden, tickets_access: 'read_only')
      scope = described_class.new(organisation: organisation, actor: actor,
                                  only_project_id: allowed.id, references: [entry('Ticket', ticket.id)])

      expect(scope.coverage_with(searched: 2, outside: true)).to eq(searched: 2, total: 2, outside: true)
      expect(scope.coverage_with(searched: 1)).to eq(searched: 1, total: 2, chosen: allowed.name)
    end

    # T-3 (plan §12): fail-closed on a type the registry does not know. No query,
    # no exception, no entry -- the same answer a deregistered type gets, which is
    # what makes deregistering one safe.
    it 'ignores an entry of an unregistered type' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      scope = described_class.new(organisation: organisation, actor: actor,
                                  references: [entry('Invoice', ticket.id), entry('Ticket', ticket.id)])

      expect(scope.references).to eq([ticket])
    end

    # Malformed stored entries answer the same way, and they are reachable: the
    # column survives a rollback of this slice, a console write, an import.
    it 'ignores a stored entry that is not a type-and-id pair' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      scope = described_class.new(organisation: organisation, actor: actor,
                                  references: [{ 'type' => 'Ticket' }, 'Ticket', nil, entry('Ticket', ticket.id)])

      expect(scope.references).to eq([ticket])
    end

    # T-6 (plan §12), the half that can be measured with one registered type. The
    # cost of resolving must not grow with the NUMBER of entries: one query for
    # the type, one for the projects the coverage sentence and the prompt need,
    # and that is all -- an entry-by-entry resolution or a lazy `record.project`
    # would turn a collection into an N+1.
    #
    # Three entries and not one, because a per-entry loop satisfies every claim
    # about a single entry. Constructed directly on Tools::Scope rather than
    # through a chat: this is the READ path, and the limit is the write path's
    # business.
    #
    # ⚠️ Warmed through the PRIVATE area_reach, not through #project_ids. Until
    # E3 that was a trap of the first order -- #project_ids applied the reference
    # narrowing, so it resolved the collection as a side effect and the
    # memoisation hid every query this example exists to count (measured: warming
    # with #project_ids made the count 0, and 0 is green for any implementation
    # at all, reference_short_circuit_blinds_query_count_guard). E3 removed that
    # side effect, so the trap is gone -- and the warming stays, because what it
    # buys is asking about the RESOLUTION's cost rather than the reach's, and
    # that was always the point.
    it 'costs the same two queries for three entries as for one, and keeps the STORED order' do
      create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')
      three = Array.new(3) { create(:ticket, project: allowed, organisation: organisation) }
      # Neither creation order nor id order, so "restores the stored order" is not
      # satisfied by simply not sorting.
      stored = [three[2], three[0], three[1]]
      scope = described_class.new(organisation: organisation, actor: actor,
                                  references: stored.map { |record| entry('Ticket', record.id) })
      scope.send(:area_reach, :tickets)

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        queries << payload[:sql] unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION CACHE])
      end
      begin
        resolved_records = scope.references
        # Reading the project must not add a query either: that is what the hand
        # preload is for, and a lazy association would pass every other assertion
        # here.
        resolved_records.map { |record| record.project.name }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(resolved_records).to eq(stored)
      expect(queries.size).to eq(2), "expected 2 queries, got #{queries.size}:\n#{queries.join("\n")}"
    end

    # The knowledge objects (doc/assistent_wissen_kontext_plan.md, step 1). Each
    # type resolves against ITS OWN area: the registry entry declares it, and
    # this is where that declaration bites. Without the per-type gate a note
    # would resolve for anyone who may read the project's tickets.
    describe 'a note and a document' do
      let(:note) { create(:note, project: allowed, organisation: organisation) }
      let(:document) do
        document = create(:document, project: allowed, organisation: organisation)
        version = create(:document_version, document: document, organisation: organisation, title: 'Angebot')
        document.update!(current_version: version)
        document
      end

      def scope_referencing(*records)
        described_class.new(organisation: organisation, actor: actor,
                            references: records.map { |record| entry(record.class.name, record.id) })
      end

      # ⚠️ No ticket right here, on purpose: with tickets readable as well, a
      # note gated by :tickets would resolve just the same and the cell would not
      # tell the two areas apart (measured -- the first version stayed green
      # under exactly that mutation).
      it 'resolves each through its own area, not through tickets' do
        create(:project_permission, user: actor, project: allowed,
                                    tickets_access: 'no_access', notes_access: 'read_only', documents_access: 'no_access')

        expect(scope_referencing(note, document).references).to eq([note])
      end

      it 'resolves the document once its area is readable' do
        create(:project_permission, user: actor, project: allowed, documents_access: 'read_only')

        expect(scope_referencing(document).references).to eq([document])
      end

      # T-6 of the Bezugs-Sammlung plan, now buildable in full: the cost of a
      # MIXED collection is one query per TYPE plus the one project load, never
      # one per entry. Document brings one more: its title is the current
      # version's, so the type preloads current versions in its own query
      # rather than lazy-loading one per document in the chip.
      #
      # Order interleaves the types on purpose: grouping by type is what makes
      # the count independent of the number of entries, and it is also what
      # loses the stored order, so the two claims stand together.
      #
      # ⚠️ TWO documents, not one. With one, a lazy current_version costs exactly
      # the one query the preload costs, and the count cannot tell them apart
      # (measured: dropping the preload left a one-document version green).
      it 'costs one query per type for a mixed collection, and keeps the STORED order' do
        create(:project_permission, user: actor, project: allowed,
                                    tickets_access: 'read_only', notes_access: 'read_only', documents_access: 'read_only')
        tickets = Array.new(2) { create(:ticket, project: allowed, organisation: organisation) }
        second_document = create(:document, project: allowed, organisation: organisation)
        second_document.update!(current_version: create(:document_version, document: second_document,
                                                                           organisation: organisation, title: 'Zweites'))
        stored = [tickets[1], note, document, tickets[0], second_document]
        scope = scope_referencing(*stored)
        %i[tickets notes documents].each { |area| scope.send(:area_reach, area) }

        queries = []
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          queries << payload[:sql] unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION CACHE])
        end
        begin
          resolved_records = scope.references
          resolved_records.map { |record| record.project.name }
          resolved_records.map { |record| record.one_line_title(max: 80) }
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        expect(resolved_records).to eq(stored)
        # tickets, notes, documents, the documents' current versions, the projects
        expect(queries.size).to eq(5), "expected 5 queries, got #{queries.size}:\n#{queries.join("\n")}"
      end
    end

    describe '.for' do
      it 'passes the thread\'s stored reference through' do
        chat = create(:chat, :org_thread, organisation: organisation, user: actor, scope_ticket: ticket)
        create(:project_permission, user: actor, project: allowed, tickets_access: 'read_only')

        expect(resolved(described_class.for(chat: chat, actor: actor))).to eq(ticket)
      end
    end
  end
end
