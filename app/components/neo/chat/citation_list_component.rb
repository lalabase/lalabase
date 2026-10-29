# frozen_string_literal: true

module Neo
  module Chat
    # Renders the source_citations attached to a chatpost as a small list beneath the
    # message body.
    #
    # Citation shapes — ONE source of truth: Lalabase::Citations. Source data comes from
    # PG JSONB → keys are STRINGS, not symbols. Code citations (vision/capability/symbol)
    # carry no link; content citations (ticket/note/document/post) carry the frozen fields
    # needed to build a link WITHOUT a DB hit (id/project_id/number/ticket_id…), a person
    # (People S3) the same without a project. Lalabase's own texts (help_page) are a third
    # kind: no area, no project, a link to /hilfe/<slug>.
    # Unknown types render with a generic label + no link, so a future type rollout never
    # crashes an old worker rendering newer data.
    #
    # The viewer-side gate (WHICH content citations are passed in) lives in
    # MessageComponent#visible_citations — this component only renders what it is given.
    class CitationListComponent < ViewComponent::Base
      # Single source of truth: Lalabase::Citations::TYPES — the same list the producer
      # (Retriever::CITATION_TYPES) uses, so the renderer's known types and the emitted
      # types can't drift apart. ICON_MAP.keys is pinned == KNOWN_TYPES by spec, so every
      # known type has an icon (unknown types still fall back gracefully — for newer JSONB
      # data rendered by an older worker mid-deploy).
      KNOWN_TYPES = Lalabase::Citations::TYPES

      # type → icon. Tested via positive iteration so a silent swap breaks a test.
      ICON_MAP = {
        'vision' => 'bi-eye',
        'capability' => 'bi-puzzle',
        'symbol' => 'bi-braces',
        'ticket' => 'bi-card-checklist',
        'note' => 'bi-journal-text',
        'document' => 'bi-file-earmark-text',
        'post' => 'bi-chat-square-quote',
        'documentation' => 'bi-book',
        'meeting' => 'bi-chat-quote',
        # An AI work product (Slice 7b) — the magic wand marks it as generated, like
        # the summary button.
        'meeting_analysis' => 'bi-magic',
        # A report over booked time (S2) — the stopwatch is the time-tracking icon.
        'time_report' => 'bi-stopwatch',
        # A page of Lalabase's own help (product knowledge S2): the icon the help wears in the
        # navigation and in the contextual help drawer.
        'help_page' => 'bi-question-circle',
        # A person of the people directory (People S3).
        'person' => 'bi-person'
      }.freeze
      FALLBACK_ICON = 'bi-bookmark'

      # organisation + project: needed to build content-citation links. MessageComponent
      # passes them derived from the chatpost (so they are present in the streaming
      # broadcast too, where Current.* is nil). Absent → links degrade to plain text.
      #
      # targets: the shared existence resolver (Feinschliff B). ChatContainerComponent
      # builds ONE for the whole transcript and hands it down, so a long conversation
      # costs one query per target type rather than one per answer. nil → this list
      # resolves its own citations, which is the single-bubble broadcast path.
      # numbering: the [n] numbering over the FULL persisted source_citations
      # (MessageComponent#source_numbering). Passed in rather than derived here
      # because this component only ever sees the viewer's filtered subset, and a
      # numbering over the subset would shift per viewer and disagree with the [n]
      # the prose resolves (R3). nil → rows carry no numbers (other render sites,
      # old callers).
      def initialize(citations:, organisation: nil, project: nil, targets: nil, numbering: nil)
        # Two layers of defense (unchanged): non-Array → empty; drop non-Hash items so a
        # malformed JSONB row never crashes the chat UI on cite['type'].
        list = citations.is_a?(Array) ? citations : []
        @citations = list.select { |c| c.is_a?(Hash) }
        @organisation = organisation
        @project = project
        @numbering = numbering
        @targets = targets || Lalabase::CitationTargets.for(citations: @citations,
                                                            organisation: organisation)
      end

      def render?
        @citations.any?
      end

      # The list as the reader sees it: one row per SOURCE, not per citation
      # (Feinschliff B, P8). Three comments of one ticket are three citations and one
      # source; before this they were three rows saying "Kommentar zu #7", all
      # pointing at the same page.
      #
      # Grouped by Lalabase::Citations.source_key_of, which agrees with the link and
      # the existence check everywhere except where a citation addresses a SLICE of
      # its target: two reports over one project are two sources with two links, and
      # the bare target would merge them (Viertreview F5). So a row that groups is
      # exactly a row that links to one place.
      def groups
        @groups ||= @citations.group_by { |c| group_key(c) }.map do |key, members|
          lead = lead_of(members, key)
          { lead: lead, size: members.size, numbers: numbers_of(members, lead) }
        end
      end

      # "[2] [5]" for a grouped row, or nil. The numbers a reader saw in the prose
      # as [n] references; a grouped row (ticket + its comments) carries every
      # member's number, the lead's first so the row's own number stays in front.
      def numbers_label(group)
        numbers = group[:numbers]
        return nil if numbers.blank?

        numbers.map { |n| "[#{n}]" }.join(' ')
      end

      # How many places inside this source the answer drew on. Rendered only from
      # two upwards: "1 Fundstelle" next to a row that IS one is noise.
      def hits_label(group)
        return nil if group[:size] < 2

        t('views.organisations.chats.citations.hits', count: group[:size])
      end

      # A source whose object is gone keeps its LABEL and loses its link: the answer
      # did draw on it, and pretending otherwise would make the answer look
      # unsourced. Only ever true on evidence — see Lalabase::CitationTargets.
      delegate :gone?, to: :@targets

      def gone_label
        t('views.organisations.chats.citations.gone')
      end

      def header
        t('views.organisations.chats.citations.header')
      end

      def icon_for(type)
        ICON_MAP.fetch(type, FALLBACK_ICON)
      end

      def label_for(citation)
        case citation['type']
        when 'vision'     then t('views.organisations.chats.citations.vision')
        when 'capability' then t('views.organisations.chats.citations.capability', name: citation['name'].to_s)
        when 'symbol'     then t('views.organisations.chats.citations.symbol',
                                 qualified_name: citation['qualified_name'].to_s)
        when 'ticket'     then t('views.organisations.chats.citations.ticket',
                                 number: citation['number'].to_i, title: citation['title'].to_s)
        when 'note'       then t('views.organisations.chats.citations.note', title: citation['title'].to_s)
        when 'document'   then t('views.organisations.chats.citations.document', title: citation['title'].to_s)
        when 'post'       then t('views.organisations.chats.citations.post', number: citation['ticket_number'].to_i)
        when 'documentation' then t('views.organisations.chats.citations.documentation', title: citation['title'].to_s)
        when 'meeting' then t('views.organisations.chats.citations.meeting', title: citation['title'].to_s)
        when 'meeting_analysis'
          t('views.organisations.chats.citations.meeting_analysis', title: citation['title'].to_s)
        when 'time_report' then t('views.organisations.chats.citations.time_report', title: citation['title'].to_s)
        when 'help_page' then t('views.organisations.chats.citations.help_page', title: citation['title'].to_s)
        when 'person' then t('views.organisations.chats.citations.person', name: citation['name'].to_s)
        else t('views.organisations.chats.citations.unknown')
        end
      end

      def location_for(citation)
        return nil unless citation['type'] == 'symbol'
        return nil if citation['file_path'].blank?

        t('views.organisations.chats.citations.symbol_location',
          file_path: citation['file_path'].to_s,
          start_line: citation['start_line'].to_i)
      end

      # Clickable target for a content citation. The address itself belongs to
      # Lalabase::CitationLink since Feinschliff C, because the prose links the same
      # objects — see that module for why there is only one builder. A deleted target
      # 404s, which is why the template asks gone? before offering the link; the link
      # stays Pundit-authorized on its own controller either way.
      def link_for(citation)
        Lalabase::CitationLink.path_for(citation, organisation: @organisation, project: @project)
      end

      # Merged into the link's data hash: absent for everything without a panel,
      # so the controller's delegated handler sees nothing to intercept.
      def artefact_data(citation)
        query = artefact_query(citation)
        query.present? ? { assistant_artefact: query } : {}
      end

      attr_reader :citations

      private

      # What makes two citations the same SOURCE -- owned by Lalabase::Citations, so
      # the rule sits next to the target derivation it deviates from. Falls back to
      # the citation's own identity where there is nothing to group by, which is the
      # code layer (a vision and a capability are separate sources with no record
      # behind them). object_id as the last resort so two id-less citations of one
      # type cannot collapse into each other.
      def group_key(citation)
        Lalabase::Citations.source_key_of(citation) ||
          [citation['type'], citation['id'].presence || citation.object_id]
      end

      # The numbers of a group's members in the FULL-list numbering, lead first,
      # rest ascending, deduped. Empty without a numbering (nil, or an inactive one
      # over an empty list) and for members the numbering does not know.
      def numbers_of(members, lead)
        return [] if @numbering.nil? || !@numbering.active?

        numbers = members.filter_map { |c| @numbering.number_for(c['type'], c['id']) }.uniq.sort
        lead_number = lead && @numbering.number_for(lead['type'], lead['id'])
        return numbers if lead_number.nil?

        [lead_number] + (numbers - [lead_number])
      end

      # Which member speaks for the group. The one whose OWN type is the group's type
      # wins: a ticket carries number and title, its comments carry neither, and the
      # meeting carries what its analysis does not. Deliberately not "the first
      # wins" — the order comes out of JSONB, and the richer hash would lose a coin
      # toss it never knew about. A slice key ('citation', type, id) matches no
      # member's type, which is right: such a group has exactly one member.
      def lead_of(members, key)
        members.find { |c| c['type'] == key[0] } || members.first
      end

      # The artefact address of a citation, for the panel controller: which panel
      # kind, and what addresses it (§8.1). Only kinds that HAVE a panel get one
      # -- everything else keeps navigating to its own page, which is what §4 says
      # objects with a page should do.
      #
      # The query alone, never a whole URL: the controller puts it behind its own
      # endpoint, so an address can choose the report but never the target.
      def artefact_query(citation)
        return nil unless citation['type'] == 'time_report'

        project_id = citation['project_id'].presence || @project&.id
        return nil if project_id.blank?

        filters = citation['filters'].is_a?(Hash) ? citation['filters'] : {}
        applied = filters.symbolize_keys.slice(*AssistantArtefactsHelper::REPORT_FILTER_KEYS).compact
        { kind: 'report', project_id: project_id }.merge(applied).to_query
      end
    end
  end
end
