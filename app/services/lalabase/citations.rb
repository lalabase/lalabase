# frozen_string_literal: true

module Lalabase
  # Builds the source-citation hashes attached to chat answers. ONE source for
  # the citation shapes so the baseline retriever (ProjectRag::Retriever) and the
  # drill-down tools emit byte-identical structures — the chatpost `source_citations`
  # JSONB + the CitationListComponent depend on these keys, so an accidental shape
  # drift between producers would silently break rendering/persistence.
  module Citations
    # The complete set of citation types the system knows — ONE source of truth shared by
    # the PRODUCER (ProjectRag::Retriever::CITATION_TYPES) and the RENDERER
    # (Neo::Chat::CitationListComponent::KNOWN_TYPES), so the two whitelists cannot drift.
    # Code citations (vision/capability/symbol) + content citations
    # (ticket/note/document/post/documentation/meeting/meeting_analysis/time_report/person) +
    # Lalabase's own texts (help_page, doc/product_knowledge_plan.md S2: no organisation, no
    # project, no area). Adding a type touches: a shape method below, this list, the component's
    # ICON_MAP + label/link branch, and (for content embedded from fragments) the
    # ContentAreaRegistry (see its header for the full cross-cutting checklist).
    TYPES = %w[vision capability symbol ticket note document post documentation meeting meeting_analysis
               time_report help_page person].freeze

    # The three kinds inside that list, so a guard iterates the right one instead of keeping a
    # hand-written table of its own (five specs did; built 12.09.2026):
    #   CODE    — the project's code layer: no area, no record behind it, no link.
    #   PRODUCT — Lalabase's own texts: no area and no organisation, but a page of their own.
    #   CONTENT — the organisation's records: an area that gates them and a link. Most also sit
    #             in a project; a person (People S3) does not, the directory belongs to the
    #             organisation, and CitationLink answers it before it looks for a project.
    # CONTENT is derived, so a new type joins it, and its guards, unless it is named above.
    CODE_TYPES = %w[vision capability symbol].freeze
    PRODUCT_TYPES = %w[help_page].freeze
    CONTENT_TYPES = (TYPES - CODE_TYPES - PRODUCT_TYPES).freeze

    module_function

    # The distinct project-content areas a citation list draws on, symbolised, ignoring
    # blank/absent areas. SINGLE source for "which content areas does this answer touch":
    # used by Chatpost#content_bearing? (Boolean → a1 gated-streaming trigger) AND
    # MessageComponent#sourced_areas (the render-gate's per-area access check). Keeping the
    # derivation here guarantees the streaming split and the render-gate agree on the SAME
    # set — a1's correctness property (the asker streams un-gated exactly when others would
    # be redacted). Code citations (vision/capability/symbol) carry no `area` → excluded.
    def areas_of(citations)
      return [] unless citations.is_a?(Array)

      citations.filter_map { |c| c['area'].to_sym if c.is_a?(Hash) && c['area'].present? }.uniq
    end

    # The OBJECT a citation points at, as `{ type:, id: }` — NOT the citation's own
    # type. A Post cites a comment but points at its TICKET (a comment has no page);
    # a MeetingAnalysis points at its MEETING; a time_report points at its PROJECT,
    # whose time list its link reopens. The code layer (vision/capability/symbol)
    # points at no record and answers nil.
    #
    # ONE owner for two questions that were answered separately before (Feinschliff B):
    # which link to build, and whether the target still exists. Grouping asks a THIRD
    # question that only looks the same -- see source_key_of, which differs exactly
    # where a citation addresses a slice of its target rather than the target.
    #
    # Reads both key flavours: JSONB hands back Strings, the producers above build
    # Symbols, and this is asked on both sides.
    #
    # ⚠️ A new content type needs a branch HERE, not just in TYPES — the positive
    # iteration in the spec fails otherwise, which is the point.
    def target_of(citation)
      return nil unless citation.is_a?(Hash)

      case fetch(citation, :type)
      when 'ticket'           then target('ticket', fetch(citation, :id))
      when 'post'             then target('ticket', fetch(citation, :ticket_id))
      when 'note'             then target('note', fetch(citation, :id))
      when 'document'         then target('document', fetch(citation, :id))
      when 'documentation'    then target('documentation', fetch(citation, :id))
      when 'meeting'          then target('meeting', fetch(citation, :id))
      when 'meeting_analysis' then target('meeting', fetch(citation, :meeting_id))
      when 'time_report'      then target('project', fetch(citation, :project_id))
      # A help page points at itself, by slug: it is no record of the organisation.
      when 'help_page'        then target('help_page', fetch(citation, :id))
      when 'person'           then person_target(citation)
      end
    end

    # A member is cited by the account, a contact by the row (see .person).
    def person_target(citation)
      member_id = fetch(citation, :member_id)
      member_id.present? ? target('member', member_id) : target('person', fetch(citation, :id))
    end

    # Types whose citation addresses a SLICE of its target rather than the target
    # itself. A time report is ONE evaluation over a project: two of them share the
    # project and are still two sources, with two filter sets and two links. The
    # citation id already carries that identity (see time_report_id) -- the producer
    # learned this once (Viertreview F5), and grouping on the bare target brought the
    # same collapse back on the render side.
    SLICE_TYPES = %w[time_report].freeze

    # What makes two citations the same SOURCE in the list -- deliberately NOT the
    # same question as target_of. They agree everywhere except for the slice types
    # above: a comment meets its ticket because both address the ticket, and two
    # reports stay apart because neither addresses the project as a whole.
    #
    # nil when there is nothing to group by (the code layer, a missing id). The
    # caller then falls back to the citation's own identity.
    def source_key_of(citation)
      return nil unless citation.is_a?(Hash)

      type = fetch(citation, :type)
      if SLICE_TYPES.include?(type)
        id = fetch(citation, :id)
        return id.blank? ? nil : ['citation', type, id]
      end

      target = target_of(citation)
      target && [target[:type], target[:id]]
    end

    # nil rather than a half target when the id is absent: a target without an id
    # addresses nothing, and the callers all branch on nil already.
    def target(type, id)
      return nil if id.blank?

      { type: type, id: id }
    end

    def fetch(hash, key)
      value = hash[key.to_s]
      value.nil? ? hash[key] : value
    end

    # Internal helpers, not part of the module's API: `Citations.fetch` in particular
    # is far too generic a name to hand out.
    private_class_method :target, :fetch, :person_target

    def vision(vision)
      { type: 'vision', id: vision.id }
    end

    def capability(capability)
      { type: 'capability', id: capability.id, name: capability.name }
    end

    def symbol(symbol)
      {
        type: 'symbol',
        id: symbol.id,
        qualified_name: symbol.qualified_name,
        file_path: symbol.file_path,
        start_line: symbol.start_line,
        end_line: symbol.end_line
      }
    end

    # Content citations (Plan §4.3). EACH carries its gating `area` (String in JSONB;
    # the render-gate symbolises it). Display fields are FROZEN at retrieval time
    # (like capability.name) so rendering needs no DB hit. Dispatches on the
    # fragment's polymorphic type; nil for an unexpected type (defensive — the
    # caller compacts).
    #
    # The type list mirrors ContentAreaRegistry — when adding a type, sync all four
    # places listed in that registry's header.
    def for_fragment(fragment)
      case fragment.fragmentable_type
      when 'Ticket'            then ticket(fragment.fragmentable)
      when 'Post'              then post(fragment.fragmentable)
      when 'Note'              then note(fragment.fragmentable)
      when 'DocumentVersion'   then document(fragment.fragmentable)
      when 'DocumentationPage' then documentation_page(fragment.fragmentable)
      when 'Meeting'           then meeting(fragment.fragmentable)
      when 'MeetingAnalysis'   then meeting_analysis(fragment.fragmentable)
      # An attachment cites its PARENT and carries no type of its own: the file has no
      # page of its own, it lives on the ticket, and that is where a reader checking the
      # answer has to go. It also keeps the chip, its icon, its link and two locale trees
      # out of this entirely. What the file is CALLED is named in the prompt label
      # instead (ProjectRag::PromptBuilder#content_label).
      when 'TicketDocument'    then ticket(fragment.fragmentable.ticket)
      when 'PostDocument'      then post(fragment.fragmentable.post)
      end
    end

    def ticket(ticket)
      { type: 'ticket', area: 'tickets', id: ticket.id, project_id: ticket.project_id,
        number: ticket.number, title: ticket.title }
    end

    def note(note)
      { type: 'note', area: 'notes', id: note.id, project_id: note.project_id, title: note.title }
    end

    # A meeting (Gespräche Slice 6) carries project_id + title directly (like a
    # note), so no parent lookup. Search retrieval requires create_embeddings via
    # the fragment query; an authorized direct read (GetMeeting) does not.
    def meeting(meeting)
      { type: 'meeting', area: 'meetings', id: meeting.id, project_id: meeting.project_id, title: meeting.title }
    end

    # A meeting analysis (Gespräche Slice 7b) has no own page → the citation links to
    # its MEETING (meeting_id carried for that). project_id comes via the meeting; title
    # is the frozen prompt snapshot. Shares the :meetings gate. Only surfaced when
    # published + search-released — the opt-in gate lives in the fragment query
    # (Fragment#for_project_context), not here.
    def meeting_analysis(analysis)
      { type: 'meeting_analysis', area: 'meetings', id: analysis.id,
        project_id: analysis.meeting.project_id, meeting_id: analysis.meeting_id,
        title: analysis.prompt_title }
    end

    # A Post is a ticket comment with no own page → the citation links to its ticket.
    def post(post)
      ticket = post.ticket
      { type: 'post', area: 'tickets', id: post.id, project_id: ticket.project_id,
        ticket_id: ticket.id, ticket_number: ticket.number }
    end

    # Documents have no own title column — the title lives on the version. We cite
    # the DOCUMENT (stable target/link), titled by the embedded version.
    def document(document_version)
      document_record(document_version.document, title: document_version.title)
    end

    # The same citation from the DOCUMENT itself, for a reader that holds one
    # without a version to title it by (Tools::GetDocument on a document whose
    # current version is missing): the answer still drew on the document's
    # existence and metadata, and an uncited answer would reach every reader
    # ungated. One shape, two entrances; #document is the titled one.
    def document_record(document, title: nil)
      { type: 'document', area: 'documents', id: document.id, project_id: document.project_id,
        title: title }
    end

    # A REPORT citation (persoenlicher_assistent_plan §8.1 / S2): the answer drew on
    # aggregated numbers, not on a record. area 'time_sessions' is the special branch
    # of ProjectPolicy#area_access? (can_view_own || can_view_all), so the render-gate
    # closes for a viewer without time access. The tool itself decides own-vs-all
    # BEFORE it counts (TimeSessions::ViewingScope); the area cannot. `filters` are
    # the scalar filter params the link rebuilds the same list view from.
    #
    # id is keyed per REPORT (project + filter digest), not per project: the Runner
    # dedups citations over (type, id), and with the bare project id two reports in
    # one turn ("July? and August?") collapsed to one chip carrying the FIRST
    # report's filters — the second number lost its checkable source (Viertreview
    # F5). Identical filters still dedup; key order does not matter.
    def time_report(project, filters = {})
      { type: 'time_report', area: 'time_sessions', id: time_report_id(project, filters),
        project_id: project.id, title: project.name, filters: filters }
    end

    # Stable per-report key: project id plus a short digest over the canonicalised
    # filters. Not security-relevant — purely a dedup identity, so 12 hex chars are
    # plenty and keep the JSONB row small.
    def time_report_id(project, filters)
      canonical = filters.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{value}" }.join('&')
      "#{project.id}:#{Digest::SHA256.hexdigest(canonical)[0, 12]}"
    end

    # An external doc page (Slice 3). area 'documentation' is a real permission
    # column → gated by the render-gate. The link target is the browsing route,
    # which addresses a page by (set_id, page-path), so both are frozen here.
    # id = page.id is the dedup key (several fragments of one page → one citation).
    def documentation_page(page)
      set = page.documentation_set
      { type: 'documentation', area: 'documentation', id: page.id, project_id: set.project_id,
        set_id: set.id, page: page.path, title: page.title }
    end

    # A page of Lalabase's own texts (doc/product_knowledge_plan.md, S2), today the help. No
    # area and no project: the help is the same for everyone who may log in, so an answer drawn
    # on it stays ungated, the way a code citation does, and its link needs neither. id is the
    # slug, the page's identity across languages and syncs (the row id is not: a sync may
    # delete a row and create it again). source says which of Lalabase's texts it is, so the
    # news (S3) can get their own link; locale is the language that was read. Takes a
    # ProductKnowledgeEntry or a ProductKnowledge::Search::Hit, which answer the same four.
    def help_page(page)
      { type: 'help_page', source: page.source, id: page.slug, locale: page.locale, title: page.title }
    end

    # A person of the people directory (People S3), from a People::Directory::Entry. area
    # 'people' is the right that gates the directory (Permission::CATEGORIES[:people]) and what
    # makes an answer drawn on it content-bearing: MessageComponent#redacted? then shows it to
    # the asker only. No project: the directory belongs to the organisation.
    #
    # A contact is cited by its row, a member by the account (member_id), the two addresses the
    # people page opens (?person_id=, ?member_id=). Also a member WITH a row: the page sends
    # ?member_id= on to the row, and a source keyed by the row would read "no longer there"
    # once the row is deleted while the member still is. name is the name the tools hand the
    # model (Entry#plain_name: the account's for a member, the row's for a contact), frozen like
    # every title here.
    def person(entry)
      if entry.member?
        { type: 'person', area: 'people', id: entry.user.id, member_id: entry.user.id, name: entry.plain_name }
      else
        { type: 'person', area: 'people', id: entry.person.id, name: entry.plain_name }
      end
    end
  end
end
