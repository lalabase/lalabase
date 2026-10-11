# frozen_string_literal: true

module Lalabase
  module Tools
    # Books time on a ticket through Actors::SaveTimeSession, the write seam the
    # web form uses (billed guards, one transaction), and answers the row the
    # HTTP API answers (TimeSessions::Serializer, D4). Inbox workflow S2.
    #
    # Mutating (D3): blocked for a read-only PAT. Record-mode (D7): authorizes
    # the ticket (:show?) and the session (:create?, TimeSessionPolicy: the
    # project's time permission) before writing, or the tripwire fires. The
    # duration takes the form the web form takes ("1:30", "90", "1.5") or plain
    # minutes.
    #
    # occurred_on is a calendar DATE for billing: the web form stores midnight of
    # the picked date and every list and report buckets by that date, so a
    # booking is dated in the actor's profile time zone (User#time_zone) and
    # stored as that date's midnight, like the form. Absent means today in that
    # zone; a timestamp is read as the date it falls on there (a call at 00:30
    # Berlin belongs to that Berlin day, not to the UTC day before), its time
    # of day is dropped.
    class CreateTimeSession < Base
      def self.requires_actor?
        true
      end

      def self.mutating?
        true
      end

      def self.authorization_mode
        :record
      end

      def self.tool_name
        'create_time_session'
      end

      def self.description
        'Books time on a ticket (identified by its UUID) for you, the token owner. Give ' \
          'the duration as duration ("1:30" for hours:minutes, "90" for minutes, "1.5" for ' \
          'decimal hours) or as duration_minutes (integer), not both; at most 24 hours per ' \
          'booking. occurred_on is the DATE of the work (ISO 8601 date, or a timestamp with ' \
          'offset or Z whose time of day is dropped; without an offset it is read as UTC) ' \
          'and defaults to today in your profile time zone; description and ' \
          'customer_description are optional. Returns the booked time session as JSON.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            ticket_id: { type: 'string', description: 'UUID of the ticket to book time on.' },
            duration: { type: 'string', description: 'Duration as "1:30" (h:mm), "90" (minutes) or "1.5" (hours).' },
            duration_minutes: { type: 'integer', description: 'Duration in minutes (alternative to duration).' },
            occurred_on: { type: 'string',
                           description: 'Date of the work: ISO 8601 date, or a timestamp (offset or Z) ' \
                                        'read as the date it falls on in your time zone; defaults to today.' },
            description: { type: 'string', description: 'Internal description of the work.' },
            customer_description: { type: 'string', description: 'Description as shown to the customer.' }
          },
          required: ['ticket_id']
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil?

        args = symbolized(args)
        ticket_id = args[:ticket_id].to_s.strip
        return Result.invalid_input('ticket_id is required') if ticket_id.empty?
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)
        return Result.invalid_input('duration or duration_minutes is required') unless duration_given?(args)
        return Result.invalid_input('give either duration or duration_minutes, not both') if both_durations?(args)

        occurred_on = occurred_on_for(args, context.actor)
        return Result.invalid_input('invalid occurred_on (expected an ISO 8601 date or timestamp)') if occurred_on.nil?

        # Inside the read scope: a ticket the caller may not read answers like a
        # missing one (Base.readable_tickets).
        ticket = readable_tickets(context, context.project.tickets).find_by(id: ticket_id)
        return Result.new(content: "No ticket found for #{ticket_id}.", citations: [], kind: :empty) if ticket.nil?

        # Two checks, as in post_comment: :show? proves the actor may see the
        # ticket at all, :create? proves the time permission in the project.
        authorize!(context, ticket, :show?)
        session = build_session(ticket, context, args, occurred_on)
        authorize!(context, session, :create?)

        result = Actors::SaveTimeSession.call(
          time_session: session, attributes: {},
          group_change: { requested: false, group: nil }, current_user: context.actor
        )
        return Result.new(error: "booking failed: #{Array(result.errors).join(', ')}") unless result.success?

        json_result(TimeSessions::Serializer.row(result.resource))
      end

      def self.duration_given?(args)
        args[:duration].to_s.strip.present? || args[:duration_minutes].present?
      end
      private_class_method :duration_given?

      # Two durations would mean one silently wins; refused instead.
      def self.both_durations?(args)
        args[:duration].to_s.strip.present? && args[:duration_minutes].present?
      end
      private_class_method :both_durations?

      # The booking date as midnight in the app zone (the form's spelling,
      # Organisations::TimeSessionsController#ensure_valid_occurred_on): absent
      # means today in the actor's zone; a timestamp is the date it falls on
      # there; unusable means nil, which the caller refuses.
      def self.occurred_on_for(args, actor)
        zone = actor.time_zone
        raw = args[:occurred_on].to_s.strip
        return zone.today.in_time_zone if raw.empty?

        Lalabase::IsoTimestamp.parse(raw)&.in_time_zone(zone)&.to_date&.in_time_zone
      end
      private_class_method :occurred_on_for

      def self.build_session(ticket, context, args, occurred_on)
        session = TimeSession.new(
          ticket: ticket, project: context.project, organisation: context.organisation,
          creator: context.actor, occurred_on: occurred_on,
          description: args[:description].to_s.presence,
          customer_description: args[:customer_description].to_s.presence
        )
        if args[:duration].to_s.strip.present?
          session.duration_string = args[:duration].to_s
        else
          session.duration = args[:duration_minutes].to_i
        end
        session
      end
      private_class_method :build_session
    end
  end
end
