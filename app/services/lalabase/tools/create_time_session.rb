# frozen_string_literal: true

module Lalabase
  module Tools
    # Books time on a ticket by the rule the HTTP API books by
    # (TimeSessions::Booking: the duration, the day, the write through
    # Actors::SaveTimeSession) and answers the row the HTTP API answers
    # (TimeSessions::Serializer, D4). Inbox workflow S2.
    #
    # Mutating (D3): blocked for a read-only PAT. Record-mode (D7): authorizes
    # the ticket (:show?) and the session (:create?, TimeSessionPolicy: the
    # project's time permission) before writing, or the tripwire fires. The
    # duration takes the form the web form takes ("1:30", "90", "1.5") or plain
    # minutes.
    #
    # occurred_on is a calendar DATE for billing, dated in the actor's profile
    # time zone; the rule is TimeSessions::Booking's.
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

      # Refusal texts of this surface (TimeSessions::Booking::REFUSALS), unchanged
      # since the tool's first answer.
      REFUSAL_TEXT = {
        duration_missing: 'duration or duration_minutes is required',
        both_durations: 'give either duration or duration_minutes, not both',
        occurred_on_invalid: 'invalid occurred_on (expected an ISO 8601 date or timestamp)'
      }.freeze

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil?

        args = symbolized(args)
        ticket_id = args[:ticket_id].to_s.strip
        return Result.invalid_input('ticket_id is required') if ticket_id.empty?
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)

        # The booking rule is shared with the HTTP API (TimeSessions::Booking);
        # it refuses unusable input before the ticket is touched.
        booking = TimeSessions::Booking.parse(
          actor: context.actor, duration_string: args[:duration], duration_minutes: args[:duration_minutes],
          occurred_on: args[:occurred_on], description: args[:description],
          customer_description: args[:customer_description]
        )
        return Result.invalid_input(REFUSAL_TEXT.fetch(booking.refusal)) if booking.refused?

        # Inside the read scope: a ticket the caller may not read answers like a
        # missing one (Base.readable_tickets).
        ticket = readable_tickets(context, context.project.tickets).find_by(id: ticket_id)
        return Result.new(content: "No ticket found for #{ticket_id}.", citations: [], kind: :empty) if ticket.nil?

        # Two checks, as in post_comment: :show? proves the actor may see the
        # ticket at all, :create? proves the time permission in the project.
        authorize!(context, ticket, :show?)
        session = booking.build(ticket: ticket)
        authorize!(context, session, :create?)

        result = booking.save(session)
        return Result.new(error: "booking failed: #{Array(result.errors).join(', ')}") unless result.success?

        json_result(TimeSessions::Serializer.row(result.resource))
      end
    end
  end
end
