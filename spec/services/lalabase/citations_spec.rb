# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Citations do
  it 'builds a vision citation' do
    vision = instance_double(ProjectLayer4Vision, id: 'v-1')
    expect(described_class.vision(vision)).to eq(type: 'vision', id: 'v-1')
  end

  it 'builds a capability citation with the name' do
    cap = instance_double(ProjectCapability, id: 'c-1', name: 'Notifications')
    expect(described_class.capability(cap)).to eq(type: 'capability', id: 'c-1', name: 'Notifications')
  end

  it 'builds a symbol citation with the full location surface (locked shape)' do
    sym = instance_double(CodeSymbol, id: 's-1', qualified_name: 'Foo#bar',
                                      file_path: 'app/foo.rb', start_line: 2, end_line: 9)
    expect(described_class.symbol(sym)).to eq(
      type: 'symbol', id: 's-1', qualified_name: 'Foo#bar',
      file_path: 'app/foo.rb', start_line: 2, end_line: 9
    )
  end

  describe 'content citations (Plan §4.3) — locked shapes carrying their gating area' do
    it 'builds a ticket citation with area + link fields' do
      ticket = instance_double(Ticket, id: 't-1', project_id: 'p-1', number: 42, title: 'Login bug')
      expect(described_class.ticket(ticket)).to eq(
        type: 'ticket', area: 'tickets', id: 't-1', project_id: 'p-1', number: 42, title: 'Login bug'
      )
    end

    it 'builds a note citation' do
      note = instance_double(Note, id: 'n-1', project_id: 'p-1', title: 'Kickoff')
      expect(described_class.note(note)).to eq(
        type: 'note', area: 'notes', id: 'n-1', project_id: 'p-1', title: 'Kickoff'
      )
    end

    it 'builds a post citation that links to its ticket (a comment has no own page)' do
      ticket = instance_double(Ticket, id: 't-1', project_id: 'p-1', number: 7)
      post = instance_double(Post, id: 'po-1', ticket: ticket)
      expect(described_class.post(post)).to eq(
        type: 'post', area: 'tickets', id: 'po-1', project_id: 'p-1', ticket_id: 't-1', ticket_number: 7
      )
    end

    it 'builds a document citation pointing at the document, titled by the version' do
      document = instance_double(Document, id: 'd-1', project_id: 'p-1')
      version = instance_double(DocumentVersion, document: document, title: 'Spec v3')
      expect(described_class.document(version)).to eq(
        type: 'document', area: 'documents', id: 'd-1', project_id: 'p-1', title: 'Spec v3'
      )
    end

    # The same shape from the document alone (Tools::GetDocument on a document
    # without a current version): still the documents area, still the document's
    # id, so the answer stays gated and the chip still links somewhere.
    it 'builds the same document citation from the document itself, untitled' do
      document = instance_double(Document, id: 'd-1', project_id: 'p-1')
      expect(described_class.document_record(document)).to eq(
        type: 'document', area: 'documents', id: 'd-1', project_id: 'p-1', title: nil
      )
    end

    it 'builds a documentation citation carrying the set + page path for the browsing link' do
      set = instance_double(DocumentationSet, id: 'ds-1', project_id: 'p-1')
      page = instance_double(DocumentationPage, id: 'dp-1', documentation_set: set,
                                                path: 'guide/intro.md', title: 'Intro')
      expect(described_class.documentation_page(page)).to eq(
        type: 'documentation', area: 'documentation', id: 'dp-1', project_id: 'p-1',
        set_id: 'ds-1', page: 'guide/intro.md', title: 'Intro'
      )
    end

    it 'builds a time_report citation: area time_sessions, keyed per report, filters frozen (S2)' do
      project = instance_double(Project, id: 'p-1', name: 'Website-Relaunch')
      citation = described_class.time_report(project, { start_date: '2026-08-01' })
      expect(citation).to include(
        type: 'time_report', area: 'time_sessions', project_id: 'p-1',
        title: 'Website-Relaunch', filters: { start_date: '2026-08-01' }
      )
      expect(citation[:id]).to start_with('p-1:')
    end

    # Viertreview F5: the Runner dedups citations over (type, id). With the bare
    # project id two reports in ONE turn (July + August) collapsed to one chip
    # carrying the FIRST report's filters — the second number lost its source.
    # Keying per report keeps one chip per report; identical filters still dedup.
    it 'keys a time_report per REPORT: same filters same id, different filters different ids' do
      project = instance_double(Project, id: 'p-1', name: 'X')
      july    = described_class.time_report(project, { start_date: '2026-07-01', end_date: '2026-07-31' })
      july2   = described_class.time_report(project, { end_date: '2026-07-31', start_date: '2026-07-01' })
      august  = described_class.time_report(project, { start_date: '2026-08-01', end_date: '2026-08-31' })

      expect(july[:id]).to eq(july2[:id])
      expect(july[:id]).not_to eq(august[:id])
    end

    it 'builds a meeting citation carrying project + title (Gespräche Slice 6)' do
      meeting = instance_double(Meeting, id: 'm-1', project_id: 'p-1', title: 'Kickoff')
      expect(described_class.meeting(meeting)).to eq(
        type: 'meeting', area: 'meetings', id: 'm-1', project_id: 'p-1', title: 'Kickoff'
      )
    end

    it 'builds a meeting_analysis citation carrying project + meeting + prompt title (Gespräche Slice 7b)' do
      # An analysis has no own page — project_id comes via the meeting, and meeting_id
      # is carried so the link deep-links to the MEETING (title = the prompt snapshot).
      meeting = instance_double(Meeting, project_id: 'p-1')
      analysis = instance_double(MeetingAnalysis, id: 'ma-1', meeting: meeting, meeting_id: 'm-1',
                                                  prompt_title: 'Entscheidungs-Protokoll')
      expect(described_class.meeting_analysis(analysis)).to eq(
        type: 'meeting_analysis', area: 'meetings', id: 'ma-1', project_id: 'p-1',
        meeting_id: 'm-1', title: 'Entscheidungs-Protokoll'
      )
    end

    describe '.for_fragment dispatch' do
      it 'routes a Ticket fragment to a ticket citation' do
        ticket = instance_double(Ticket, id: 't-1', project_id: 'p-1', number: 1, title: 'T')
        frag = instance_double(Fragment, fragmentable_type: 'Ticket', fragmentable: ticket)
        expect(described_class.for_fragment(frag)).to include(type: 'ticket', id: 't-1', area: 'tickets')
      end

      it 'routes a DocumentVersion fragment to a document citation' do
        document = instance_double(Document, id: 'd-1', project_id: 'p-1')
        version = instance_double(DocumentVersion, document: document, title: 'V')
        frag = instance_double(Fragment, fragmentable_type: 'DocumentVersion', fragmentable: version)
        expect(described_class.for_fragment(frag)).to include(type: 'document', id: 'd-1', area: 'documents')
      end

      # The two MIDDLE dispatch branches: a direct shape test (post/note above) does NOT
      # prove the for_fragment WIRING — `when 'Post' then note(...)` (wrong shape/area) or a
      # deleted `when 'Note'` (a real note fragment silently swallowed to nil) would survive.
      it 'routes a Post fragment to a post citation with the tickets area (not notes)' do
        ticket = instance_double(Ticket, id: 't-1', project_id: 'p-1', number: 7)
        post = instance_double(Post, id: 'po-1', ticket: ticket)
        frag = instance_double(Fragment, fragmentable_type: 'Post', fragmentable: post)
        expect(described_class.for_fragment(frag)).to include(type: 'post', id: 'po-1', area: 'tickets')
      end

      # An attachment cites its PARENT rather than carrying a type of its own: the file
      # has no page, it lives on the ticket, and that is where a reader verifying the
      # answer has to go. Reusing the shape also keeps the chip, its icon and its link
      # out of this change entirely.
      it 'routes a TicketDocument fragment to the citation of its ticket' do
        ticket = instance_double(Ticket, id: 't-1', project_id: 'p-1', number: 12, title: 'Angebot')
        document = instance_double(TicketDocument, ticket: ticket)
        frag = instance_double(Fragment, fragmentable_type: 'TicketDocument', fragmentable: document)
        expect(described_class.for_fragment(frag)).to include(type: 'ticket', id: 't-1', area: 'tickets')
      end

      it 'routes a PostDocument fragment to the citation of its comment' do
        ticket = instance_double(Ticket, id: 't-1', project_id: 'p-1', number: 12)
        post = instance_double(Post, id: 'po-1', ticket: ticket)
        document = instance_double(PostDocument, post: post)
        frag = instance_double(Fragment, fragmentable_type: 'PostDocument', fragmentable: document)
        expect(described_class.for_fragment(frag)).to include(type: 'post', id: 'po-1', area: 'tickets')
      end

      it 'routes a Note fragment to a note citation (not swallowed to nil)' do
        note = instance_double(Note, id: 'n-1', project_id: 'p-1', title: 'Kickoff')
        frag = instance_double(Fragment, fragmentable_type: 'Note', fragmentable: note)
        expect(described_class.for_fragment(frag)).to include(type: 'note', id: 'n-1', area: 'notes')
      end

      it 'routes a DocumentationPage fragment to a documentation citation' do
        set = instance_double(DocumentationSet, id: 'ds-1', project_id: 'p-1')
        page = instance_double(DocumentationPage, id: 'dp-1', documentation_set: set, path: 'a.md', title: 'A')
        frag = instance_double(Fragment, fragmentable_type: 'DocumentationPage', fragmentable: page)
        expect(described_class.for_fragment(frag)).to include(type: 'documentation', id: 'dp-1', area: 'documentation')
      end

      it 'routes a Meeting fragment to a meeting citation (Gespräche Slice 6)' do
        meeting = instance_double(Meeting, id: 'm-1', project_id: 'p-1', title: 'Kickoff')
        frag = instance_double(Fragment, fragmentable_type: 'Meeting', fragmentable: meeting)
        expect(described_class.for_fragment(frag)).to include(type: 'meeting', id: 'm-1', area: 'meetings')
      end

      it 'routes a MeetingAnalysis fragment to a meeting_analysis citation (Gespräche Slice 7b)' do
        meeting = instance_double(Meeting, project_id: 'p-1')
        analysis = instance_double(MeetingAnalysis, id: 'ma-1', meeting: meeting, meeting_id: 'm-1',
                                                    prompt_title: 'Decisions')
        frag = instance_double(Fragment, fragmentable_type: 'MeetingAnalysis', fragmentable: analysis)
        expect(described_class.for_fragment(frag)).to include(type: 'meeting_analysis', id: 'ma-1', area: 'meetings')
      end

      it 'returns nil for an unexpected fragmentable type (defensive — the caller compacts)' do
        frag = instance_double(Fragment, fragmentable_type: 'User', fragmentable: nil)
        expect(described_class.for_fragment(frag)).to be_nil
      end
    end

    it 'every content citation area (ALL seven types) maps back to a registered ContentAreaRegistry area (R2 drift guard)' do
      # Catches a singular drift like area:'document' instead of 'documents' — which would
      # silently over-redact the render-gate via a non-existent permission. Covers ALL seven
      # producing shape methods (ticket/note/post/document/documentation/meeting/meeting_analysis).
      registry_areas = Lalabase::ProjectRag::ContentAreaRegistry::AREA_BY_TYPE.values.map(&:to_s)
      ticket   = instance_double(Ticket, id: 't', project_id: 'p', number: 1, title: 'T')
      note     = instance_double(Note, id: 'n', project_id: 'p', title: 'N')
      post     = instance_double(Post, id: 'po', ticket: instance_double(Ticket, id: 't2', project_id: 'p', number: 2))
      document = instance_double(Document, id: 'd', project_id: 'p')
      version  = instance_double(DocumentVersion, document: document, title: 'V')
      doc_set  = instance_double(DocumentationSet, id: 'ds', project_id: 'p')
      doc_page = instance_double(DocumentationPage, id: 'dp', documentation_set: doc_set, path: 'a.md', title: 'D')
      meeting  = instance_double(Meeting, id: 'm', project_id: 'p', title: 'M')
      analysis = instance_double(MeetingAnalysis, id: 'ma', meeting: instance_double(Meeting, project_id: 'p'),
                                                  meeting_id: 'm', prompt_title: 'A')
      citations = [described_class.ticket(ticket), described_class.note(note),
                   described_class.post(post), described_class.document(version),
                   described_class.documentation_page(doc_page), described_class.meeting(meeting),
                   described_class.meeting_analysis(analysis)]
      citations.each { |c| expect(registry_areas).to include(c[:area]) }
      expect(citations.map { |c| c[:area] }.uniq)
        .to contain_exactly('tickets', 'notes', 'documents', 'documentation', 'meetings')
    end
  end

  describe '.areas_of — the single area derivation shared by streaming split + render-gate' do
    # This method is the SSoT both Chatpost#content_bearing? (a1 gated-streaming trigger)
    # and MessageComponent#sourced_areas (render-gate) consult. If it drifts, the asker can
    # be streamed content the render-gate would redact for everyone else. So it is pinned hard.
    it 'returns the distinct content areas as Symbols (not Strings — area_access? wants symbols)' do
      citations = [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => 't1' },
                   { 'type' => 'note',   'area' => 'notes',   'id' => 'n1' }]
      expect(described_class.areas_of(citations)).to contain_exactly(:tickets, :notes)
    end

    it 'deduplicates repeated areas (a ticket + a post citation → ONE :tickets)' do
      # Kills a dropped `.uniq`: without it the render-gate would query the same area twice.
      citations = [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => 't1' },
                   { 'type' => 'post',   'area' => 'tickets', 'id' => 'p1' }]
      expect(described_class.areas_of(citations)).to eq([:tickets])
    end

    it 'excludes code citations that carry no area key (vision/capability/symbol)' do
      citations = [{ 'type' => 'symbol', 'id' => 's1' }, { 'type' => 'vision', 'id' => 'v1' }]
      expect(described_class.areas_of(citations)).to eq([])
    end

    it 'ignores a blank area string — a malformed citation must NOT become :"" (the drift the SSoT prevents)' do
      # Without the `present?` filter, ''.to_sym → :"" would reach the render-gate as a
      # non-existent area AND content_bearing? (present? → false) would disagree → exactly
      # the asker-streams-redacted-content bug this single derivation exists to prevent.
      expect(described_class.areas_of([{ 'type' => 'ticket', 'area' => '', 'id' => 't1' }])).to eq([])
    end

    it 'ignores a nil area without raising' do
      expect(described_class.areas_of([{ 'type' => 'symbol', 'area' => nil, 'id' => 's1' }])).to eq([])
    end

    it 'skips non-Hash entries instead of raising (defensive over malformed JSONB)' do
      # nil/42 would blow up on []('area') without the is_a?(Hash) guard.
      expect(described_class.areas_of([nil, 42, { 'type' => 'ticket', 'area' => 'tickets', 'id' => 't1' }]))
        .to eq([:tickets])
    end

    it 'returns [] for a non-Array argument (source_citations can be {} / nil in the wild)' do
      expect(described_class.areas_of(nil)).to eq([])
      expect(described_class.areas_of({})).to eq([])
    end

    it 'returns [] for an empty citation list' do
      expect(described_class.areas_of([])).to eq([])
    end
  end

  # ONE owner of "which object does this citation point at" (Feinschliff B).
  # Three callers need the same answer: the link builder, the existence check and
  # the grouping in the source list. Two of them derived it by hand before, which
  # is why a ticket and its comments appeared as separate sources.
  describe '.target_of' do
    it 'points a ticket at itself' do
      expect(described_class.target_of('type' => 'ticket', 'id' => 't-1'))
        .to eq(type: 'ticket', id: 't-1')
    end

    it 'points a POST at its ticket, not at the comment' do
      expect(described_class.target_of('type' => 'post', 'id' => 'p-9', 'ticket_id' => 't-1'))
        .to eq(type: 'ticket', id: 't-1')
    end

    it 'points a meeting analysis at its MEETING' do
      expect(described_class.target_of('type' => 'meeting_analysis', 'id' => 'a-1', 'meeting_id' => 'm-1'))
        .to eq(type: 'meeting', id: 'm-1')
    end

    it 'points a time report at its PROJECT (its link is that project time list)' do
      expect(described_class.target_of('type' => 'time_report', 'id' => 'p-1:abc', 'project_id' => 'p-1'))
        .to eq(type: 'project', id: 'p-1')
    end

    it 'accepts symbol keys as well (producers build those, JSONB returns strings)' do
      expect(described_class.target_of(type: 'note', id: 'n-1')).to eq(type: 'note', id: 'n-1')
    end

    it 'answers nil for the code layer, which points at no record' do
      described_class::CODE_TYPES.each do |type|
        expect(described_class.target_of('type' => type, 'id' => 'x')).to be_nil
      end
    end

    it 'answers nil for an unknown type and for a non-Hash (defense in depth)' do
      expect(described_class.target_of('type' => 'something_new', 'id' => 'x')).to be_nil
      expect(described_class.target_of('not a hash')).to be_nil
      expect(described_class.target_of(nil)).to be_nil
    end

    it 'answers nil when the id the target hangs on is missing' do
      expect(described_class.target_of('type' => 'post', 'id' => 'p-9')).to be_nil
      expect(described_class.target_of('type' => 'meeting_analysis', 'id' => 'a-1')).to be_nil
    end

    # Positive iteration over the type list, so a NEW citation type cannot be added
    # without deciding what it points at. The code layer is the documented exception.
    it 'answers for every known content type' do
      (described_class::CONTENT_TYPES + described_class::PRODUCT_TYPES).each do |type|
        cite = { 'type' => type, 'id' => 'x', 'ticket_id' => 'x', 'meeting_id' => 'x', 'project_id' => 'x' }
        expect(described_class.target_of(cite)).not_to be_nil, "#{type} points nowhere"
      end
    end
  end

  # The GROUPING identity, which is deliberately not the target: a report addresses a
  # slice of its project, so two reports meet at the same target and are still two
  # sources with two different links. Everything else groups by its target.
  # Category 4: the tables are a contract, not an accident. One that can grow at
  # runtime is not a whitelist.
  describe 'the type tables' do
    it 'are frozen' do
      expect(described_class::TYPES).to be_frozen
      expect(described_class::SLICE_TYPES).to be_frozen
      expect(described_class::CODE_TYPES).to be_frozen
      expect(described_class::PRODUCT_TYPES).to be_frozen
      expect(described_class::CONTENT_TYPES).to be_frozen
    end

    # The taxonomy the guards iterate (12.09.2026). Pinned in BOTH directions: the three kinds
    # cover TYPES exactly, and each holds what it says. Without the second half, moving a type
    # into PRODUCT_TYPES would quietly excuse it from every content guard.
    it 'split TYPES into exactly three kinds, none overlapping' do
      expect(described_class::CODE_TYPES + described_class::PRODUCT_TYPES + described_class::CONTENT_TYPES)
        .to match_array(described_class::TYPES)
      expect(described_class::CODE_TYPES).to contain_exactly('vision', 'capability', 'symbol')
      expect(described_class::PRODUCT_TYPES).to contain_exactly('help_page')
      # person (People S3) is content WITHOUT a project: the area gates it and it has a page,
      # so every content guard applies to it. A fourth kind would excuse it from all of them.
      expect(described_class::CONTENT_TYPES).to include('ticket', 'note', 'time_report', 'person')
    end

    it 'name only types the shapes actually know' do
      expect(described_class::SLICE_TYPES - described_class::TYPES).to be_empty
    end

    # Same reason as for SKIP_ANCESTORS: a loop over the constant survives the
    # constant shrinking. The content needs its own pin.
    # time_report is the slice type that exists today: a report is ONE calculation
    # over a project, not the project.
    it 'names the report as the slice type it is' do
      expect(described_class::SLICE_TYPES).to include('time_report')
    end
  end

  describe '.source_key_of' do
    def report(filters)
      described_class.time_report(project_double, filters).deep_stringify_keys
    end

    let(:project_double) { instance_double(Project, id: 'p-1', name: 'Nordlicht') }

    it 'keeps two reports over the SAME project apart' do
      july = report('start_date' => '2026-07-01')
      august = report('start_date' => '2026-08-01')

      # Flow anchor: they DO share a target, which is why grouping on the target
      # collapsed them (Viertreview F5, reintroduced at the render layer).
      expect(described_class.target_of(july)).to eq(described_class.target_of(august))
      expect(described_class.source_key_of(july)).not_to eq(described_class.source_key_of(august))
    end

    it 'still meets a comment with its ticket' do
      ticket = { 'type' => 'ticket', 'id' => 't-1' }
      comment = { 'type' => 'post', 'id' => 'p-9', 'ticket_id' => 't-1' }

      expect(described_class.source_key_of(comment)).to eq(described_class.source_key_of(ticket))
    end

    it 'answers nil where there is no target, so the caller falls back to the citation itself' do
      expect(described_class.source_key_of('type' => 'vision', 'id' => 'v-1')).to be_nil
      expect(described_class.source_key_of('not a hash')).to be_nil
    end

    # Category 2: one cell per slice type. If one drops out of SLICE_TYPES, two reports
    # of the same project collapse into one row again -- exactly the defect the review
    # of #622 found.
    it 'keeps two citations of the same target apart for EVERY slice type' do
      # Without this line the loop is vacuously green on an emptied list: it
      # iterates over nothing and still claims something.
      expect(described_class::SLICE_TYPES).not_to be_empty

      described_class::SLICE_TYPES.each do |type|
        first = { 'type' => type, 'id' => "#{type}-1", 'project_id' => 'p-1' }
        second = { 'type' => type, 'id' => "#{type}-2", 'project_id' => 'p-1' }

        expect(described_class.source_key_of(first)).not_to eq(described_class.source_key_of(second)),
                                                            "two #{type} citations of one project collapsed"
      end
    end

    # The counter-check: everything that is NOT a slice collapses onto its target.
    # Without this half one could widen SLICE_TYPES to all types and the cell above
    # would stay green while the grouping no longer groups anything.
    it 'collapses two citations onto their shared target for everything that is NOT a slice' do
      ticket = { 'type' => 'ticket', 'id' => 't-1' }
      comment = { 'type' => 'post', 'id' => 'p-9', 'ticket_id' => 't-1' }

      expect(described_class::SLICE_TYPES).not_to include('ticket', 'post')
      expect(described_class.source_key_of(comment)).to eq(described_class.source_key_of(ticket))
    end

    it 'answers for every known content type (positive iteration, like .target_of)' do
      (described_class::CONTENT_TYPES + described_class::PRODUCT_TYPES).each do |type|
        cite = { 'type' => type, 'id' => 'x', 'ticket_id' => 'x', 'meeting_id' => 'x', 'project_id' => 'x' }
        expect(described_class.source_key_of(cite)).not_to be_nil, "#{type} has no source key"
      end
    end
  end

  # Lalabase's own help (doc/product_knowledge_plan.md, S2): a third kind next to code and
  # content, without an area like the one and with a page like the other.
  describe '.help_page' do
    let(:page) do
      build(:product_knowledge_entry, slug: 'guides/features/time-tracking', locale: 'en', title: 'Time tracking')
    end

    it 'cites the page by slug, with its source and language, and without area or project' do
      expect(described_class.help_page(page)).to eq(
        type: 'help_page', source: 'help', id: 'guides/features/time-tracking', locale: 'en', title: 'Time tracking'
      )
    end

    it 'takes a search hit as well as a row, the two things the help tools hold' do
      hit = ProductKnowledge::Search::Hit.new(source: 'help', locale: 'de', slug: 'guides/a/b', title: 'B')

      expect(described_class.help_page(hit)).to include(id: 'guides/a/b', locale: 'de', title: 'B')
    end

    # The rights gate runs on the areas of an answer's citations. None here, so an answer drawn
    # only on the help reaches every reader, which is right: every reader may open /hilfe.
    it 'leaves an answer drawn on it ungated' do
      expect(described_class.areas_of([described_class.help_page(page).deep_stringify_keys])).to eq([])
    end

    it 'points at the page itself, so two citations of one page are one source' do
      cite = described_class.help_page(page).deep_stringify_keys

      expect(described_class.target_of(cite)).to eq(type: 'help_page', id: 'guides/features/time-tracking')
      expect(described_class.source_key_of(cite)).to eq(%w[help_page guides/features/time-tracking])
    end
  end

  # A person of the people directory (People S3): content of the organisation without a
  # project. A contact is cited by its row, a member by the account, the two addresses the
  # people page opens (?person_id=, ?member_id=).
  describe '.person' do
    let(:row) { instance_double(Person, id: 'pe-1', name: 'Doris Dienstleister') }
    let(:account) { instance_double(User, id: 'u-1', display_name: 'Carl Kollege') }
    let(:contact) { People::Directory::Entry.new(kind: :contact, user: nil, person: row) }
    let(:member) { People::Directory::Entry.new(kind: :member, user: account, person: nil) }
    let(:member_with_row) do
      People::Directory::Entry.new(kind: :member, user: account,
                                   person: instance_double(Person, id: 'pe-2', name: 'C. Kollege (alt)'))
    end

    it 'cites a contact by its row, with the people area and the name' do
      expect(described_class.person(contact)).to eq(type: 'person', area: 'people', id: 'pe-1',
                                                    name: 'Doris Dienstleister')
    end

    it 'cites a member by the account, with the name from the account' do
      expect(described_class.person(member)).to eq(type: 'person', area: 'people', id: 'u-1', member_id: 'u-1',
                                                   name: 'Carl Kollege')
    end

    # A member's page follows the account whether or not the member has a row: the people
    # page sends ?member_id= on to the row. Cited by the row instead, the source would read
    # "no longer there" once the row is deleted, while the member still is.
    it 'cites a member with a row of their own by the account too, named from the account' do
      expect(described_class.person(member_with_row)).to eq(type: 'person', area: 'people', id: 'u-1',
                                                            member_id: 'u-1', name: 'Carl Kollege')
    end

    # The area is the right that gates the directory (Permission::CATEGORIES[:people]), and
    # what makes an answer drawn on it content-bearing: MessageComponent#redacted? then shows
    # it to the asker only.
    it 'carries the people area, which makes an answer drawn on it content-bearing' do
      expect(Permission::CATEGORIES).to have_key(:people)
      expect(described_class.areas_of([described_class.person(contact).deep_stringify_keys])).to eq([:people])
    end

    it 'points a contact at its row and a member at the account' do
      expect(described_class.target_of(described_class.person(contact).deep_stringify_keys))
        .to eq(type: 'person', id: 'pe-1')
      expect(described_class.target_of(described_class.person(member).deep_stringify_keys))
        .to eq(type: 'member', id: 'u-1')
    end

    it 'groups two citations of one person into one source' do
      cite = described_class.person(member).deep_stringify_keys

      expect(described_class.source_key_of(cite)).to eq(described_class.source_key_of(cite.dup))
      expect(described_class.source_key_of(cite))
        .not_to eq(described_class.source_key_of(described_class.person(contact).deep_stringify_keys))
    end
  end
end
