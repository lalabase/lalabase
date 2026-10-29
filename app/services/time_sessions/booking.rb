# frozen_string_literal: true

# The one rule of a time booking through a token: the MCP tool
# create_time_session and POST /api/v1/tickets/:ticket_id/time_sessions both
# book through it, so the two surfaces cannot drift apart again (before, REST
# saved raw, dated a booking "now" and let one duration silently win).
#
# Entry point: parse
#
# Three steps, because the callers authorize in between: `parse` refuses
# unusable input before the caller builds or authorizes the booking (MCP
# before its ticket lookup, REST inside its read gate), `build` makes the unsaved
# booking on a ticket the caller has found readable, and `save` writes it
# through Actors::SaveTimeSession (billed guards, one transaction) once the
# caller has authorized the booking itself (:create?, the project's time
# permission). Rights stay with the callers; this object holds none.
#
# occurred_on is a calendar DAY for billing: the web form stores midnight of
# the picked day and every list and report buckets by that day. A booking is
# therefore dated in the actor's profile zone (User#time_zone) and stored as
# that day's midnight. Absent means today there; a timestamp is the day it
# falls on there (00:30 in Berlin belongs to that Berlin day, not to the UTC
# day before), a timestamp without an offset is read as UTC; a plain date is
# that day.
module TimeSessions
  class Booking
    # Why `parse` turns an input away. Each caller words it for its surface.
    REFUSALS = %i[duration_missing both_durations duration_minutes_invalid occurred_on_invalid].freeze

    PLAIN_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    WHOLE_MINUTES = /\A\s*\d+\s*\z/

    attr_reader :refusal

    def self.parse(actor:, duration_string: nil, duration_minutes: nil, occurred_on: nil,
                   description: nil, customer_description: nil)
      new(actor: actor, duration_string: duration_string.to_s.strip.presence,
          duration_minutes: absent?(duration_minutes) ? nil : duration_minutes, occurred_on: occurred_on,
          description: description, customer_description: customer_description)
    end

    def initialize(actor:, duration_string:, duration_minutes:, occurred_on:, description:, customer_description:)
      @actor = actor
      @duration_string = duration_string
      @duration_minutes = duration_minutes
      @description = description.to_s.strip.presence && description.to_s
      @customer_description = customer_description.to_s.strip.presence && customer_description.to_s
      @refusal = refusal_for(occurred_on)
    end

    # Absent is nil or blank text; false, 0 and other values are given.
    def self.absent?(value)
      value.nil? || (value.is_a?(String) && value.strip.empty?)
    end
    private_class_method :absent?

    def refused?
      !@refusal.nil?
    end

    # The unsaved booking on `ticket`, in the ticket's project and organisation.
    def build(ticket:)
      raise ArgumentError, "refused booking: #{@refusal}" if refused?

      session = TimeSession.new(
        ticket: ticket, project: ticket.project, organisation: ticket.organisation,
        creator: @actor, occurred_on: @day,
        description: @description, customer_description: @customer_description
      )
      if @duration_string
        session.duration_string = @duration_string
      else
        session.duration = @duration_minutes.to_i
      end
      session
    end

    # => Actors::BaseActor::Result. A model refusal (a duration over a day, a
    # duration that is no time) comes back as :validation_failed, nothing written.
    def save(session)
      Actors::SaveTimeSession.call(
        time_session: session, attributes: {},
        group_change: { requested: false, group: nil }, current_user: @actor
      )
    end

    private

    # The duration first, then the date, the order the MCP tool always answered in.
    def refusal_for(occurred_on)
      return :duration_missing if @duration_string.nil? && @duration_minutes.nil?
      return :both_durations if @duration_string && !@duration_minutes.nil?
      return :duration_minutes_invalid unless @duration_minutes.nil? || whole_minutes?(@duration_minutes)

      @day = day_for(occurred_on)
      :occurred_on_invalid if @day.nil?
    end

    # A whole number of minutes, as a number or as digits. A fraction would be
    # cut to the minute below ("1.5" booked as 1, while duration_string "1.5"
    # is 90 minutes); anything else is no number. Zero and negative numbers pass
    # here and are refused by the model (duration > 0).
    def whole_minutes?(value)
      value.is_a?(Integer) || (value.is_a?(String) && value.match?(WHOLE_MINUTES))
    end

    # Midnight (app zone) of the booking's day, or nil for input that is no date.
    def day_for(raw)
      raw = raw.to_s.strip
      zone = @actor.time_zone
      return zone.today.in_time_zone if raw.empty?

      parsed = Lalabase::IsoTimestamp.parse(raw)
      return nil if parsed.nil?

      day = raw.match?(PLAIN_DATE) ? parsed.to_date : parsed.in_time_zone(zone).to_date
      day.in_time_zone
    end
  end
end
