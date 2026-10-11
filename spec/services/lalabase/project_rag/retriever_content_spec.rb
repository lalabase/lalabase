# frozen_string_literal: true

require 'rails_helper'

# Failing-first (PE-2, Plan §3/§4): the retriever additionally pulls semantically
# relevant project content (tickets/posts/notes/documents) from `fragments` —
# ASKER-SCOPED (per-area gate via ProjectPolicy#area_access?) and within
# the hard boundary (org + exactly chat.project + private posts excluded).
#
# The setup pattern (roles/membership/ProjectPermission/Fragment) is mirrored from
# spec/services/combined_search_service_spec.rb. These specs are deliberately red
# until the extension exists (asker:, Result#content, ContentAreaRegistry,
# Fragment.for_project_context, Citations.ticket/post/note/document).
#
# Since embedding v2 PR 4b the content layer reads the content_embeddings sidecar,
# so every seeded fragment mirrors its vector there (mirror_embedding_to_sidecar) —
# an inline-only seed would be invisible to retrieval.
RSpec.describe Lalabase::ProjectRag::Retriever, 'project content (PE-2)' do
  let(:organisation)  { create(:organisation) }
  let(:project)       { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }

  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }
  let(:admin_role)    { create(:role, title: 'account_admin', organisation: organisation) }

  let(:asker) do
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    u
  end

  let(:chat) { build(:chat, organisation: organisation).tap(&:save!) }

  # Deterministic query embedding (no real API call).
  let(:query_embedding) { Array.new(1536, 0.1) }
  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil,
                                                   embed_with_usage: { embedding: query_embedding, total_tokens: 5 },
                                                   provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    stub_default_embedding_space
    pin_exact_vector_scans
  end

  after { ActsAsTenant.current_tenant = nil }

  def vec(seed = 0.1)
    Array.new(1536, seed)
  end

  def grant(user, target_project, **areas)
    create(:project_permission, { user: user, project: target_project }.merge(areas))
  end

  # Embedded fragment for an arbitrary fragmentable — the record plus its sidecar
  # row, exactly as the write path persists it, so the retrieval path finds it.
  def content_fragment(fragmentable, seed: 0.1, content: 'projektwissen fragment')
    fragment = create(:fragment, fragmentable: fragmentable, organisation: fragmentable.organisation, plain_text_content: content)
    seed_sidecar_embedding(fragment, vector: vec(seed))
    fragment
  end

  def retrieve(asker_override: asker)
    described_class.new(chat: chat, query: 'wie ist der stand?', asker: asker_override,
                        embed_provider: embed_provider).call
  end

  def retrieved_sources(result)
    result.content.map(&:fragmentable)
  end

  # Counts real SELECT queries (ignores schema/transaction/cached) during the block.
  def count_select_queries(&block)
    count = 0
    sub = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      count += 1 if payload[:sql].lstrip.start_with?('SELECT')
    end
    ActiveSupport::Notifications.subscribed(sub, 'sql.active_record', &block)
    count
  end

  describe 'asker gate (per area)' do
    let!(:ticket)   { create(:ticket, project: project, organisation: organisation, creator: asker) }
    let!(:fragment) { content_fragment(ticket) }

    it 'includes ticket content when the asker may read :tickets' do
      grant(asker, project, tickets_access: 'read_only')
      expect(retrieved_sources(retrieve)).to include(ticket)
    end

    it 'excludes ticket content when the asker has NO ticket permission at all' do
      expect(retrieved_sources(retrieve)).not_to include(ticket)
    end

    it 'excludes ticket content when tickets_access is explicitly no_access' do
      grant(asker, project, tickets_access: 'no_access')
      expect(retrieved_sources(retrieve)).not_to include(ticket)
    end

    it 'includes ticket content when the asker has read_write (write implies read)' do
      # Positive iteration over the access-level whitelist: all other gate tests grant only
      # read_only/no_access. A read_write asker (write permission) MUST be allowed to read —
      # otherwise the mutation that removes read_write from the :read permission
      # (ProjectAccessService) survives.
      grant(asker, project, tickets_access: 'read_write')
      expect(retrieved_sources(retrieve)).to include(ticket)
    end

    it 'emits a ticket citation carrying its area when permitted' do
      grant(asker, project, tickets_access: 'read_only')
      cite = retrieve.citations.find { |c| c[:type] == 'ticket' }
      expect(cite).to include(type: 'ticket', id: ticket.id, area: 'tickets', project_id: project.id)
    end

    it 'emits ONE citation per ticket even when several of its fragments are retrieved (R4 dedup)' do
      grant(asker, project, tickets_access: 'read_only')
      content_fragment(ticket, seed: 0.1, content: 'erstes fragment des tickets')
      content_fragment(ticket, seed: 0.1, content: 'zweites fragment des tickets')
      ticket_cites = retrieve.citations.select { |c| c[:type] == 'ticket' && c[:id] == ticket.id }
      expect(ticket_cites.size).to eq(1)
    end

    # Differential gate (pins the type→area mapping): grant ONE area, deny the other,
    # then assert each type follows its OWN area. A mutation that maps Note→:tickets
    # (or makes the gate area-blind) leaks the note in here — these two catch it.
    it 'with tickets allowed but notes denied: ticket content in, note content out' do
      grant(asker, project, tickets_access: 'read_only', notes_access: 'no_access')
      note = create(:note, project: project, organisation: organisation, creator: asker)
      content_fragment(note)
      sources = retrieved_sources(retrieve)
      expect(sources).to include(ticket)
      expect(sources).not_to include(note)
    end

    it 'with notes allowed but tickets denied: note content in, ticket content out' do
      grant(asker, project, tickets_access: 'no_access', notes_access: 'read_only')
      note = create(:note, project: project, organisation: organisation, creator: asker)
      content_fragment(note)
      sources = retrieved_sources(retrieve)
      expect(sources).to include(note)
      expect(sources).not_to include(ticket)
    end
  end

  describe 'DocumentVersion content (fourth fragmentable type — full retriever path)' do
    def document_version_in(target_project)
      doc = create(:document, project: target_project, organisation: organisation)
      create(:document_version, document: doc, organisation: organisation)
    end

    it 'includes a document version when the asker may read :documents, with a document citation' do
      grant(asker, project, documents_access: 'read_only')
      dv = document_version_in(project)
      content_fragment(dv)
      result = retrieve
      expect(retrieved_sources(result)).to include(dv)
      cite = result.citations.find { |c| c[:type] == 'document' }
      expect(cite).to include(type: 'document', id: dv.document_id, area: 'documents', project_id: project.id)
    end

    it 'excludes a document version whose document is in another project' do
      grant(asker, project, documents_access: 'read_only')
      other_dv = document_version_in(other_project)
      content_fragment(other_dv)
      expect(retrieved_sources(retrieve)).not_to include(other_dv)
    end

    it 'excludes document content when the asker may NOT read :documents (per-area gate)' do
      grant(asker, project, documents_access: 'no_access')
      dv = document_version_in(project)
      content_fragment(dv)
      expect(retrieved_sources(retrieve)).not_to include(dv)
    end
  end

  describe 'DocumentationPage content (fifth fragmentable type — double-gate T6)' do
    def doc_page_in(target_project, removed: false)
      set = create(:documentation_set, project: target_project, organisation: organisation)
      create(:documentation_page, documentation_set: set, organisation: organisation,
                                  removed_at: removed ? Time.current : nil)
    end

    it 'includes a doc page when the asker may read :documentation, with a documentation citation' do
      grant(asker, project, documentation_access: 'read_only')
      page = doc_page_in(project)
      content_fragment(page)

      result = retrieve
      expect(retrieved_sources(result)).to include(page)
      cite = result.citations.find { |c| c[:type] == 'documentation' }
      expect(cite).to include(type: 'documentation', id: page.id, area: 'documentation',
                              project_id: project.id, set_id: page.documentation_set_id, page: page.path)
    end

    # T6 double-gate (MANDATORY security test): a chat asker WITHOUT :documentation
    # read right must get NO doc content — even though the fragment exists and the
    # chat gate itself is satisfied. The registry maps the type to :documentation and
    # the retriever's per-area gate enforces it.
    it 'excludes doc content when the asker may NOT read :documentation (explicit no_access)' do
      grant(asker, project, documentation_access: 'no_access')
      page = doc_page_in(project)
      content_fragment(page)

      expect(retrieved_sources(retrieve)).not_to include(page)
    end

    it 'excludes doc content when the asker has NO documentation permission row at all' do
      page = doc_page_in(project)
      content_fragment(page)

      expect(retrieved_sources(retrieve)).not_to include(page)
    end

    it 'includes doc content for a read_write asker (write implies read)' do
      grant(asker, project, documentation_access: 'read_write')
      page = doc_page_in(project)
      content_fragment(page)

      expect(retrieved_sources(retrieve)).to include(page)
    end

    # ⚠️ Turned around by projekt_chat_abbau. This used to assert a HARD PROJECT
    # BOUNDARY: the thread had one project and content from any other was excluded
    # even where the asker had access. There is no thread with a project any more, so
    # the boundary IS the asker's per-area reach -- and content they may read in a
    # second project is exactly what the assistant is for. The negative half of the
    # rule (no permission, no content) is pinned by its own example below.
    it 'includes a doc page from another project the asker may read there' do
      grant(asker, project, documentation_access: 'read_only')
      grant(asker, other_project, documentation_access: 'read_only')
      other_page = doc_page_in(other_project)
      content_fragment(other_page)

      expect(retrieved_sources(retrieve)).to include(other_page)
    end

    # Defense-in-depth: even if a fragment somehow lingers for a soft-removed page
    # (the sync purges them, but bugs happen), a removed page must never ground.
    it 'excludes a soft-removed doc page even when a fragment still exists' do
      grant(asker, project, documentation_access: 'read_only')
      page = doc_page_in(project, removed: true)
      content_fragment(page)

      expect(retrieved_sources(retrieve)).not_to include(page)
    end

    # R1 (the security property the render-gate rests on) for the NEW type: doc content
    # that reaches the result MUST be covered by an area-bearing citation, or it would
    # slip past the render-gate (sourced_areas is derived from the citations). Mirrors
    # the mandatory ticket/note R1 test, but for documentation.
    it 'covers retrieved doc content with a documentation area citation (R1)' do
      grant(asker, project, documentation_access: 'read_only')
      page = doc_page_in(project)
      content_fragment(page)

      result = retrieve
      content_areas = result.content
                            .map { |f| Lalabase::ProjectRag::ContentAreaRegistry.area_for(f.fragmentable_type) }
                            .compact.uniq
      sourced_areas = result.citations.filter_map { |c| c[:area]&.to_sym }.uniq
      expect(content_areas).to include(:documentation)
      expect(content_areas - sourced_areas).to be_empty
    end

    # R4 dedup for the new type: several fragments of ONE page collapse to ONE citation
    # (page.id is the dedup key). A mutant using set_id as the citation id, or dropping
    # the dedup, would surface duplicates here.
    it 'emits ONE documentation citation even when several fragments of the page are retrieved' do
      grant(asker, project, documentation_access: 'read_only')
      page = doc_page_in(project)
      content_fragment(page, content: 'erster doku-abschnitt')
      content_fragment(page, content: 'zweiter doku-abschnitt')

      cites = retrieve.citations.select { |c| c[:type] == 'documentation' && c[:id] == page.id }
      expect(cites.size).to eq(1)
    end
  end

  # Sixth fragmentable type (Gespräche Slice 6) — DOUBLE gate: the :meetings area
  # read right (like DocumentationPage) AND the per-meeting create_embeddings opt-in
  # (unique to meetings, PII data class). Both must hold, or no grounding.
  describe 'Meeting content (sixth fragmentable type — opt-in + area double-gate)' do
    def meeting_in(target_project, embeddings: true)
      create(:meeting, project: target_project, organisation: organisation, creator: asker,
                       create_embeddings: embeddings, notes: 'projektwissen aus dem gespraech')
    end

    it 'includes an opted-in meeting when the asker may read :meetings, with a meeting citation' do
      grant(asker, project, meetings_access: 'read_only')
      meeting = meeting_in(project)
      content_fragment(meeting)

      result = retrieve
      expect(retrieved_sources(result)).to include(meeting)
      cite = result.citations.find { |c| c[:type] == 'meeting' }
      expect(cite).to include(type: 'meeting', id: meeting.id, area: 'meetings', project_id: project.id)
    end

    it 'includes an opted-in meeting for a read_write asker (write implies read)' do
      grant(asker, project, meetings_access: 'read_write')
      meeting = meeting_in(project)
      content_fragment(meeting)
      expect(retrieved_sources(retrieve)).to include(meeting)
    end

    # THE core security test (plan §7 "Chat zitiert Meeting ohne Leserecht"): no
    # :meetings read right → no meeting content, even though the fragment exists.
    it 'excludes meeting content when the asker may NOT read :meetings (explicit no_access)' do
      grant(asker, project, meetings_access: 'no_access')
      meeting = meeting_in(project)
      content_fragment(meeting)
      expect(retrieved_sources(retrieve)).not_to include(meeting)
    end

    it 'excludes meeting content when the asker has NO meetings permission row at all' do
      meeting = meeting_in(project)
      content_fragment(meeting)
      expect(retrieved_sources(retrieve)).not_to include(meeting)
    end

    # Defense-in-depth (the opt-in half of the double gate): even WITH :meetings read,
    # a meeting whose create_embeddings is off must never ground — a fragment orphaned
    # by a later opt-out can't leak (plan §7 "Rohtranskript ungewollt auffindbar").
    it 'excludes an opted-OUT meeting even for a permitted asker (create_embeddings = false)' do
      grant(asker, project, meetings_access: 'read_only')
      meeting = meeting_in(project, embeddings: false)
      content_fragment(meeting)
      expect(retrieved_sources(retrieve)).not_to include(meeting)
    end

    # Same turnaround as the doc page above (projekt_chat_abbau): reach, not project.
    it 'includes a meeting from another project the asker may read there' do
      grant(asker, project, meetings_access: 'read_only')
      grant(asker, other_project, meetings_access: 'read_only')
      other_meeting = meeting_in(other_project)
      content_fragment(other_meeting)
      expect(retrieved_sources(retrieve)).to include(other_meeting)
    end

    # R1: retrieved meeting content MUST be covered by an area-bearing citation, or it
    # slips past the render-gate (sourced_areas derives from the citations).
    it 'covers retrieved meeting content with a meetings area citation (R1)' do
      grant(asker, project, meetings_access: 'read_only')
      meeting = meeting_in(project)
      content_fragment(meeting)

      result = retrieve
      content_areas = result.content
                            .map { |f| Lalabase::ProjectRag::ContentAreaRegistry.area_for(f.fragmentable_type) }
                            .compact.uniq
      sourced_areas = result.citations.filter_map { |c| c[:area]&.to_sym }.uniq
      expect(content_areas).to include(:meetings)
      expect(content_areas - sourced_areas).to be_empty
    end
  end

  # Seventh fragmentable type (Gespräche Slice 7b) — TRIPLE gate: the :meetings area
  # read right (like Meeting) AND published (is_private = false) AND search-released
  # (include_in_search = true). The publish+search half is per-analysis and independent
  # of the meeting's own create_embeddings opt-in (D13 redaction use-case).
  describe 'MeetingAnalysis content (seventh fragmentable type — publish + search + area gate)' do
    # The meeting is intentionally created WITHOUT create_embeddings: an analysis is
    # embedded independently of its meeting's own opt-in (D13).
    def analysis_in(target_project, is_private: false, in_search: true)
      meeting = create(:meeting, project: target_project, organisation: organisation, creator: asker,
                                 create_embeddings: false)
      create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: asker,
                                is_private: is_private, include_in_search: in_search,
                                content: 'entscheidung aus der analyse')
    end

    it 'includes a published+search-released analysis when the asker may read :meetings, with a citation' do
      grant(asker, project, meetings_access: 'read_only')
      analysis = analysis_in(project)
      content_fragment(analysis)

      result = retrieve
      expect(retrieved_sources(result)).to include(analysis)
      cite = result.citations.find { |c| c[:type] == 'meeting_analysis' }
      expect(cite).to include(type: 'meeting_analysis', id: analysis.id, area: 'meetings',
                              project_id: project.id, meeting_id: analysis.meeting_id)
    end

    it 'includes it for a read_write asker (write implies read)' do
      grant(asker, project, meetings_access: 'read_write')
      analysis = analysis_in(project)
      content_fragment(analysis)
      expect(retrieved_sources(retrieve)).to include(analysis)
    end

    # THE core security test (plan §5, Entscheidung 5 "Privat wird NIE embedded"): a
    # private analysis must NEVER surface in the chat of ANY user — even the creator who
    # sees it in the UI, and even if a fragment somehow lingers (defense-in-depth; the
    # actor purges on de-index). Chat exposure ⊂ UI visibility: the row filter
    # is_private = FALSE guarantees it. This is the most important assertion of Slice 7b.
    it 'excludes a PRIVATE analysis even for its own creator with a lingering fragment (Entscheidung 5)' do
      grant(asker, project, meetings_access: 'read_only')
      analysis = analysis_in(project, is_private: true) # visible_to = creator = asker in the UI
      content_fragment(analysis)
      expect(retrieved_sources(retrieve)).not_to include(analysis)
    end

    # Defense-in-depth (the search half): a published-but-NOT-search-released analysis
    # must never ground, even with :meetings read and a lingering fragment.
    it 'excludes a published analysis that is NOT search-released (include_in_search = false)' do
      grant(asker, project, meetings_access: 'read_only')
      analysis = analysis_in(project, is_private: false, in_search: false)
      content_fragment(analysis)
      expect(retrieved_sources(retrieve)).not_to include(analysis)
    end

    # THE area gate (plan §5 double-gate): no :meetings read → no analysis content.
    it 'excludes analysis content when the asker may NOT read :meetings (explicit no_access)' do
      grant(asker, project, meetings_access: 'no_access')
      analysis = analysis_in(project)
      content_fragment(analysis)
      expect(retrieved_sources(retrieve)).not_to include(analysis)
    end

    it 'excludes analysis content when the asker has NO meetings permission row at all' do
      analysis = analysis_in(project)
      content_fragment(analysis)
      expect(retrieved_sources(retrieve)).not_to include(analysis)
    end

    # Same turnaround as the doc page and the meeting (projekt_chat_abbau): reach,
    # not project. The two examples right above keep the negative half.
    it 'includes an analysis from another project the asker may read there' do
      grant(asker, project, meetings_access: 'read_only')
      grant(asker, other_project, meetings_access: 'read_only')
      other_analysis = analysis_in(other_project)
      content_fragment(other_analysis)
      expect(retrieved_sources(retrieve)).to include(other_analysis)
    end

    # R1: retrieved analysis content MUST be covered by an area-bearing citation, or it
    # slips past the render-gate (sourced_areas derives from the citations).
    it 'covers retrieved analysis content with a meetings area citation (R1)' do
      grant(asker, project, meetings_access: 'read_only')
      analysis = analysis_in(project)
      content_fragment(analysis)

      result = retrieve
      content_areas = result.content
                            .map { |f| Lalabase::ProjectRag::ContentAreaRegistry.area_for(f.fragmentable_type) }
                            .compact.uniq
      sourced_areas = result.citations.filter_map { |c| c[:area]&.to_sym }.uniq
      expect(content_areas).to include(:meetings)
      expect(content_areas - sourced_areas).to be_empty
    end
  end

  # ⚠️ Was "hard project boundary (independent of the gate)". projekt_chat_abbau
  # replaced the project boundary with the ASKER'S REACH: a thread carries no project,
  # so the only boundary left is per-area, per-project permission -- plus the tenant,
  # which is not a permission and never moves.
  describe 'the boundary is the asker\'s reach, and the tenant' do
    it 'returns a ticket fragment from another project the asker may read there' do
      grant(asker, project, tickets_access: 'read_only')
      grant(asker, other_project, tickets_access: 'read_only')
      other_ticket = create(:ticket, project: other_project, organisation: organisation, creator: asker)
      content_fragment(other_ticket)
      expect(retrieved_sources(retrieve)).to include(other_ticket)
    end

    it 'never returns a ticket fragment from a project the asker may NOT read' do
      grant(asker, project, tickets_access: 'read_only')
      grant(asker, other_project, tickets_access: 'no_access')
      other_ticket = create(:ticket, project: other_project, organisation: organisation, creator: asker)
      content_fragment(other_ticket)
      expect(retrieved_sources(retrieve)).not_to include(other_ticket)
    end

    it 'never returns a fragment from another organisation (tenant isolation)' do
      grant(asker, project, tickets_access: 'read_only')
      own_ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(own_ticket)

      foreign = nil
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        op = create(:project, organisation: other_org)
        ot = create(:ticket, project: op, organisation: other_org, creator: create(:user))
        foreign = content_fragment(ot, content: 'foreign org content')
      end

      result = retrieve
      expect(result.content).not_to include(foreign)
      expect(result.content.map(&:organisation_id).uniq).to eq([organisation.id])
    end

    it 'still excludes a foreign-org fragment WITHOUT tenant scope (not only via default_scope)' do
      # Proves cross-org ISOLATION without depending on the acts_as_tenant default_scope.
      # Unlike in the symbol layer, here the project JOIN carries the boundary (project_id is
      # unique across orgs) — the explicit organisation_id filter is redundant at this
      # point (defense-in-depth, see fetch_content). So this test pins the isolation, NOT
      # the necessity of the filter line.
      grant(asker, project, tickets_access: 'read_only')
      content_fragment(create(:ticket, project: project, organisation: organisation, creator: asker))

      foreign = nil
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        op = create(:project, organisation: other_org)
        ot = create(:ticket, project: op, organisation: other_org, creator: create(:user))
        foreign = content_fragment(ot, content: 'foreign')
      end

      content = ActsAsTenant.without_tenant { retrieve.content }
      expect(content).not_to include(foreign)
    end
  end

  describe 'private posts are never surfaced (v1 simplification, Plan §5)' do
    it 'excludes a private post even for an account-admin asker' do
      admin = create(:user)
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      ticket = create(:ticket, project: project, organisation: organisation, creator: admin)
      private_post = create(:post, ticket: ticket, organisation: organisation,
                                   is_private: true, visible_to_user_id: nil)
      content_fragment(private_post)
      expect(retrieved_sources(retrieve(asker_override: admin))).not_to include(private_post)
    end

    it 'includes a public (non-private) post for a permitted asker' do
      grant(asker, project, tickets_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      public_post = create(:post, ticket: ticket, organisation: organisation, is_private: false)
      content_fragment(public_post)
      expect(retrieved_sources(retrieve)).to include(public_post)
    end
  end

  describe 'fail-closed when the asker is unknown' do
    it 'returns no content when asker is nil (job could not resolve last_user_post.user)' do
      grant(asker, project, tickets_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket)
      expect(retrieve(asker_override: nil).content).to be_empty
    end
  end

  describe 'CONTENT_TOP_K contract' do
    before { grant(asker, project, tickets_access: 'read_only') }

    it 'caps content at exactly CONTENT_TOP_K when more exist (n+1 boundary)' do
      (described_class::CONTENT_TOP_K + 1).times do |i|
        t = create(:ticket, project: project, organisation: organisation, creator: asker)
        content_fragment(t, seed: 0.1 + (i * 0.001))
      end
      expect(retrieve.content.size).to eq(described_class::CONTENT_TOP_K)
    end

    it 'returns exactly CONTENT_TOP_K when exactly K exist (n boundary)' do
      described_class::CONTENT_TOP_K.times do |i|
        t = create(:ticket, project: project, organisation: organisation, creator: asker)
        content_fragment(t, seed: 0.1 + (i * 0.001))
      end
      expect(retrieve.content.size).to eq(described_class::CONTENT_TOP_K)
    end

    it 'returns all when fewer than K exist (n-1 boundary)' do
      (described_class::CONTENT_TOP_K - 1).times do |i|
        t = create(:ticket, project: project, organisation: organisation, creator: asker)
        content_fragment(t, seed: 0.1 + (i * 0.001))
      end
      expect(retrieve.content.size).to eq(described_class::CONTENT_TOP_K - 1)
    end
  end

  # R1 (MANDATORY, Plan §4.3/§9): foundation of the render-gate. Every content area pulled
  # into the prompt (= Result#content) MUST be covered by an area-bearing citation —
  # otherwise it leaks past the render-gate (sourced_areas is derived from the citations).
  # Breaks red as soon as a content path pulls an item into the prompt without emitting
  # an area citation.
  describe 'R1: sourced_areas-Vollständigkeit (Prompt-Content ⇒ area-Citation)' do
    it 'covers every content area reaching the prompt with a citation area (symbolised, R2)' do
      grant(asker, project, tickets_access: 'read_only', notes_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      note   = create(:note, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket, seed: 0.1)
      content_fragment(note, seed: 0.1)

      result = retrieve
      content_areas = result.content
                            .map { |f| Lalabase::ProjectRag::ContentAreaRegistry.area_for(f.fragmentable_type) }
                            .compact.uniq
      sourced_areas = result.citations.filter_map { |c| c[:area]&.to_sym }.uniq

      expect(content_areas).not_to be_empty
      expect(content_areas - sourced_areas).to be_empty
    end

    it 'leaves no content fragment in the prompt without an attributable citation' do
      grant(asker, project, tickets_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket, seed: 0.1)

      result = retrieve
      citation_ids = result.citations.filter_map { |c| c[:id] if c[:area] }
      result.content.each do |fragment|
        citation = Lalabase::Citations.for_fragment(fragment)
        expect(citation).not_to be_nil
        expect(citation_ids).to include(citation[:id])
      end
    end
  end

  # #6 / R3-adjacent: the citation targets (Post→ticket, DocumentVersion→document)
  # must load in a CONSTANT number of queries, not one per item. Compares 1 vs 5
  # posts: equal query count proves the Preloader batches (no N+1).
  describe 'N+1 safety: citation targets preloaded in constant queries' do
    it 'does not grow the query count with the number of content items' do
      grant(asker, project, tickets_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      add_posts = lambda do |n|
        n.times do
          post = create(:post, ticket: ticket, organisation: organisation, is_private: false)
          content_fragment(post, seed: 0.1)
        end
      end

      add_posts.call(1)
      retrieve # warmup: prime schema/column caches so they don't skew the first count
      one_item = count_select_queries { retrieve }

      add_posts.call(4) # five posts total
      five_items = count_select_queries { retrieve }

      expect(five_items).to eq(one_item)
    end
  end

  describe 'embedding edge case' do
    it 'excludes a fragment with a NULL embedding while keeping embedded ones' do
      # A fragment can exist without an embedding (EmbeddingProcessingService not yet run
      # or failed) and must never surface. Since PR 4b this is STRUCTURAL rather than a
      # filter: no embedding means no content_embeddings row, and the M1 inner join
      # therefore yields no hit — which is why fetch_content no longer carries an
      # explicit `where.not(embedding: nil)`. The test pins the BEHAVIOR, unchanged
      # across the switch.
      grant(asker, project, tickets_access: 'read_only')
      embedded = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(embedded, seed: 0.1)
      unembedded = create(:ticket, project: project, organisation: organisation, creator: asker)
      create(:fragment, fragmentable: unembedded, organisation: organisation, plain_text_content: 'noch nicht embeddet')

      sources = retrieved_sources(retrieve)
      expect(sources).to include(embedded)
      expect(sources).not_to include(unembedded)
    end
  end

  # Integration test (not just a unit test): actually send the retrieved Result through the
  # REAL PromptBuilder — proves that the content ends up in the prompt AND that the R1
  # coupling (prompt content ⇒ area citation) holds across the whole chain.
  describe 'integration: Retriever → PromptBuilder (content reaches the prompt, R1 end-to-end)' do
    it 'feeds retrieved content into the prompt and keeps every prompt area citation-covered' do
      grant(asker, project, tickets_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker, title: 'Login-Bug')
      content_fragment(ticket, seed: 0.1, content: 'Reproduktionsschritte fuer den Login-Bug')

      result = retrieve
      prompt = Lalabase::ProjectRag::PromptBuilder.new(result: result).call

      expect(prompt).to include('Project Knowledge')
      expect(prompt).to include('Reproduktionsschritte fuer den Login-Bug')

      content_areas = result.content
                            .map { |f| Lalabase::ProjectRag::ContentAreaRegistry.area_for(f.fragmentable_type) }
                            .compact.uniq
      sourced = result.citations.filter_map { |c| c[:area]&.to_sym }.uniq
      expect(content_areas).not_to be_empty
      expect(content_areas - sourced).to be_empty
    end
  end

  # S3a T3 (Plan §9.1): the org thread has no project, so the content layer
  # resolves its reach PER AREA (accessible_project_ids) with the same per-area
  # gate — a project outside the asker's reach must never surface (§12-S3a).
  # The code layers (vision/capabilities/symbols) stay deliberately empty: they
  # are pinned to a single project/repo and the org thread has neither.
  describe 'org-wide content (S3a T3)' do
    let(:org_chat) do
      ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, user: asker) }
    end

    def org_retrieve(asker_override: asker)
      described_class.new(chat: org_chat, query: 'wie ist der stand?', asker: asker_override,
                          embed_provider: embed_provider).call
    end

    it 'pulls content from a readable project and never from a no-access one (§12-S3a)' do
      readable_ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      foreign_ticket  = create(:ticket, project: other_project, organisation: organisation, creator: asker)
      content_fragment(readable_ticket)
      content_fragment(foreign_ticket, seed: 0.1)
      grant(asker, project, tickets_access: 'read_only')

      sources = retrieved_sources(org_retrieve)

      expect(sources).to include(readable_ticket)
      expect(sources).not_to include(foreign_ticket)
    end

    it 'keeps the per-area split per project: notes access does not surface ticket fragments' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      note   = create(:note, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket)
      content_fragment(note, seed: 0.1)
      grant(asker, project, notes_access: 'read_only')

      sources = retrieved_sources(org_retrieve)

      expect(sources).to include(note)
      expect(sources).not_to include(ticket)
    end

    it 'stays empty without an asker (fail-closed)' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket)
      grant(asker, project, tickets_access: 'read_only')

      expect(org_retrieve(asker_override: nil).content.to_a).to eq([])
    end

    it 'gives an inactive member nothing, permission row or not (same gate as the single-project path)' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket)
      grant(asker, project, tickets_access: 'read_only')
      asker.memberships.find_by(organisation: organisation).update!(active: false)

      expect(retrieved_sources(org_retrieve)).to eq([])
    end

    # Content served AND code layers empty in one example: without the served
    # content the empty code layers would also hold for the plain empty_result.
    it 'runs the content layer only: code layers stay empty while content is served' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: asker)
      content_fragment(ticket)
      grant(asker, project, tickets_access: 'read_only')

      result = org_retrieve

      expect(retrieved_sources(result)).to include(ticket)
      expect(result.vision).to be_nil
      expect(result.capabilities).to eq([])
      expect(result.symbols).to eq([])
    end

    # L7 on the knowledge path: the retrieval reports how many projects it reached
    # for at least one area, so a tool-free answer wears its narrowing too.
    it 'reports its coverage: projects reached for at least one area against all active projects' do
      other_project # exists, out of reach
      grant(asker, project, tickets_access: 'read_only')

      expect(org_retrieve.coverage).to eq(searched: 1, total: 2)
    end

    it 'counts a project reached through ANY area once' do
      grant(asker, project, tickets_access: 'read_only', notes_access: 'read_only')
      grant(asker, other_project, notes_access: 'read_only')

      expect(org_retrieve.coverage).to eq(searched: 2, total: 2)
    end

    # S3a T5: the knowledge path's coverage must come from Tools::Scope, not from a
    # hand-built hash. The chip's `chosen` key rides in that hash, and
    # ChatResponseJob#narrowest_coverage keeps the FIRST of two equally narrow
    # ones -- this is the one passed first, so a hand-built hash here silently
    # outvotes the tool coverage that does carry the chip, and "Durchsucht: nur
    # Nordlicht" never reaches a single answer.
    it 'names the chip project in its coverage, like the tools do' do
      grant(asker, project, tickets_access: 'read_only')
      grant(asker, other_project, tickets_access: 'read_only')
      org_chat.update!(scope_project: project)

      expect(org_retrieve.coverage).to eq(searched: 1, total: 2, chosen: project.name)
    end

    # Was: "carries no coverage on the single-project path (not applicable)". There is
    # no such path since projekt_chat_abbau, so coverage is ALWAYS carried -- which is
    # what the examples above assert. Turned into the pin that the field is never nil,
    # because a nil there is how a narrowed answer would silently lose its label.
    it 'always carries coverage, because there is only the org path' do
      grant(asker, project, tickets_access: 'read_only')

      expect(retrieve.coverage).to include(:searched, :total)
    end
  end
  # Eighth and ninth fragmentable types: the files hanging off a ticket and off a
  # comment. They were embedded long before this and reachable from nowhere — the
  # registry, the joins and the predicates all skipped them, so the vector existed and
  # no query could ever return it. Gated by :tickets, exactly like the object they
  # hang on; a comment attachment additionally inherits its comment's privacy.
  describe 'attachment content (eighth and ninth fragmentable types)' do
    def ticket_in(target_project)
      create(:ticket, project: target_project, organisation: organisation, creator: asker)
    end

    def attachment_on(target_project, text: 'angebot ueber 4200 euro')
      create(:ticket_document, :with_pdf, ticket: ticket_in(target_project),
                                          organisation: organisation, plain_text_version: text)
    end

    def comment_attachment_on(target_project, private_comment: false)
      post = create(:post, ticket: ticket_in(target_project), organisation: organisation,
                           user: asker, is_private: private_comment)
      create(:post_document, :with_pdf, post: post, organisation: organisation,
                                        plain_text_version: 'nachtrag zum angebot')
    end

    it 'includes a ticket attachment when the asker may read :tickets, citing its ticket' do
      grant(asker, project, tickets_access: 'read_only')
      document = attachment_on(project)
      content_fragment(document)

      result = retrieve
      expect(retrieved_sources(result)).to include(document)
      cite = result.citations.find { |c| c[:type] == 'ticket' }
      expect(cite).to include(type: 'ticket', id: document.ticket_id, area: 'tickets',
                              project_id: project.id)
    end

    it 'includes a comment attachment on a public comment' do
      grant(asker, project, tickets_access: 'read_only')
      document = comment_attachment_on(project)
      content_fragment(document)

      expect(retrieved_sources(retrieve)).to include(document)
    end

    # THE area gate: an attachment must not be the way around the read right of the
    # object it hangs on. Without :tickets the ticket itself is unreachable, and its
    # file has to be too.
    it 'excludes a ticket attachment when the asker may NOT read :tickets' do
      grant(asker, project, tickets_access: 'no_access')
      document = attachment_on(project)
      content_fragment(document)

      expect(retrieved_sources(retrieve)).not_to include(document)
    end

    # The privacy half, and the reason PostDocument cannot simply reuse the Ticket
    # predicate: a private comment is excluded from the content layer entirely, so the
    # file hanging off it must go the same way. Otherwise the attachment is a hole in
    # exactly the wall the comment stands behind.
    it 'excludes the attachment of a PRIVATE comment even with :tickets read' do
      grant(asker, project, tickets_access: 'read_only')
      document = comment_attachment_on(project, private_comment: true)
      content_fragment(document)

      expect(retrieved_sources(retrieve)).not_to include(document)
    end

    it 'excludes an attachment from a project the asker cannot reach' do
      grant(asker, project, tickets_access: 'read_only')
      document = attachment_on(other_project)
      content_fragment(document)

      expect(retrieved_sources(retrieve)).not_to include(document)
    end
  end
end
