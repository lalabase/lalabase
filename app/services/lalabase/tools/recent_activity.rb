# frozen_string_literal: true

module Lalabase
  module Tools
    # What happened recently, across the projects the asker may see (assistant
    # plan §9a Befund 1, §13-11).
    #
    # Rights, and why this tool checks them itself (§13-9): an activity row has no
    # project_id and no area of its own. Both are derived -- the project from the
    # trackable, the area from the KEY -- and that derivation lives in
    # Activities::VisibleTo / Activities::AreaRegistry, which this tool goes
    # through. There is nothing the content-area table could gate here.
    #
    # ⚠️ ASSISTANT SET ONLY, deliberately. The rows span areas (a note event, a
    # member change, a ticket move), but only ticket rows can carry a citation, so
    # the render gate of a SHARED thread could not redact the rest. An org thread
    # is owner-only (§6.1), which is what makes this safe today; offering the tool
    # on a SHARED surface would need per-area citations first.
    class RecentActivity < Base
      DEFAULT_DAYS = 7
      MAX_DAYS = 90
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200
      MAX_CITATIONS = 5

      # ⚠️ A WHITELIST, not a pass-through of `parameters`. Two fields in there
      # must never reach a prompt:
      #   * `post_excerpt` (ticket.post_added) is comment CONTENT, and a comment
      #     carries its own privacy (visible_to_user_id) that the :tickets area
      #     does not express -- exactly the gap issue #267 describes,
      #   * `user_email` (project.member_added) is personal data the answer does
      #     not need to be useful.
      # Everything else that is not listed here is simply left out.
      SUBJECT_FIELDS = %w[display_name note_title document_title meeting_title ticket_title user_name].freeze

      def self.requires_actor?
        true
      end

      def self.tool_name
        'recent_activity'
      end

      def self.description
        'Lists what happened recently across the projects the asking user may ' \
          'see: tickets created, assigned, moved, commented on, status and ' \
          'priority changes, plus notes, documents, meetings and member changes ' \
          'of a project. Each event carries its timestamp, the person who caused ' \
          'it, a machine-readable key like "ticket.status_changed", the project ' \
          'and a short subject. Answers "what happened last week?" from the ' \
          'database rather than from search. Rows the user may not see are ' \
          'filtered out per area before counting, and coverage says how many of ' \
          'the organisation\'s projects the answer reaches. Billing runs and ' \
          'organisation administration are not part of this feed.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            days: { type: 'integer',
                    description: "How many days back to look. Default #{DEFAULT_DAYS}, maximum #{MAX_DAYS}." },
            limit: { type: 'integer',
                     description: "Maximum number of events to return. Default #{DEFAULT_LIMIT}, " \
                                  "maximum #{MAX_LIMIT}. The total count is reported either way." }
          },
          required: []
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'org-wide context missing') unless org_wide?(context)

        args = symbolized(args)
        days = clamp(args[:days], DEFAULT_DAYS, MAX_DAYS)
        limit = clamp(args[:limit], DEFAULT_LIMIT, MAX_LIMIT)
        since = days.days.ago

        feed = Activities::VisibleTo.new(organisation: context.organisation,
                                         reach: context.scope, since: since)
        visible = feed.call
        # The COUNT covers the whole window, the rows are capped: a shortened list
        # that does not say so reads as the complete answer.
        total = visible.count
        # includes(:actor): every event names who caused it, and without the
        # preload that is one query per row (Prosopite fails the spec, rightly).
        rows = visible.includes(:actor).limit(limit).to_a
        # ⚠️ NOT coverage(area: :tickets). This feed spans every area, so a number
        # taken from ONE of them describes the wrong reach -- and the sentence it
        # renders ("Durchsucht: N von M Projekten") is the one that tells the user
        # their rights stopped somewhere. A notes-only reader got an answer out of
        # three projects labelled "0 von 3". The feed's own reach is the honest
        # denominator, and asking for it costs nothing: #call just asked for it as
        # the PROJECT_LEVEL gate, and Tools::Scope memoises per area.
        #
        # coverage_with, not a bare hash: it also carries the `chosen` name when
        # the thread's project chip narrowed the scope (S3a T5).
        coverage = context.scope.coverage_with(searched: feed.reached_project_ids.size)

        return empty_result(days, coverage) if rows.empty?

        tickets = ticket_lookup(rows)
        names = project_names(rows, tickets)
        json_result(
          {
            since: since.to_date.to_s,
            days: days,
            total: total,
            shown: rows.size,
            truncated: total > rows.size,
            events: rows.map { |row| event(row, tickets, names) }
          },
          citations: citations_for(tickets),
          coverage: coverage
        )
      end

      def self.empty_result(days, coverage)
        Result.new(content: "No activity in the last #{days} days.", citations: [], kind: :empty,
                   coverage: coverage)
      end
      private_class_method :empty_result

      def self.clamp(raw, default, max)
        value = raw.to_i
        return default unless value.positive?

        [value, max].min
      end
      private_class_method :clamp

      # Ticket rows name their ticket from the RECORD, not from the parameters:
      # `display_name` is a snapshot from the moment of the event and a renamed
      # ticket would be reported under its old name.
      def self.ticket_lookup(rows)
        ids = rows.select { |row| row.trackable_type == 'Ticket' }.map(&:trackable_id)
        return {} if ids.empty?

        Ticket.where(id: ids).index_by(&:id)
      end
      private_class_method :ticket_lookup

      # One query for every project name in the batch, rather than one per row.
      # Computed once in #execute and handed down: a memo on the class would be
      # state shared across calls, which is the wrong shape for a tool that runs
      # per request.
      def self.project_names(rows, tickets)
        ids = rows.filter_map { |row| project_id_of(row, tickets) }.uniq
        Project.where(id: ids).pluck(:id, :name).to_h
      end
      private_class_method :project_names

      def self.project_id_of(row, tickets)
        return row.trackable_id if row.trackable_type == 'Project'

        tickets[row.trackable_id]&.project_id
      end
      private_class_method :project_id_of

      def self.event(row, tickets, names)
        project_id = project_id_of(row, tickets)
        {
          at: row.created_at.iso8601,
          actor: row.actor&.full_name,
          key: row.key,
          project: { id: project_id, name: names[project_id] }.compact,
          subject: subject(row, tickets)
        }.compact
      end
      private_class_method :event

      def self.subject(row, tickets)
        ticket = tickets[row.trackable_id] if row.trackable_type == 'Ticket'
        return "##{ticket.number} #{ticket.title}".strip if ticket

        (row.parameters || {}).values_at(*SUBJECT_FIELDS).compact.first
      end
      private_class_method :subject

      # Only the tickets can be cited: they are the one type an activity row
      # points at by record. That is enough for the chips to work; see the class
      # comment for why this tool is not offered on a shared surface.
      def self.citations_for(tickets)
        tickets.values.first(MAX_CITATIONS).map { |ticket| Lalabase::Citations.ticket(ticket) }
      end
      private_class_method :citations_for
    end
  end
end
