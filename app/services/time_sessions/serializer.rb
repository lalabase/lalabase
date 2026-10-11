# frozen_string_literal: true

# JSON row of a time session in its ticket context, shared by the HTTP API
# (GET/POST /api/v1/tickets/:id/time_sessions) and the MCP tool
# create_time_session (D4), so a booking reads the same on both surfaces. The
# open-hours row (Api::V1::TimeSessionsController#serialize_open) is a different
# shape with project and ticket inline and stays where it is.
#
# Entry point: row
module TimeSessions
  class Serializer
    def self.row(session)
      {
        id: session.id,
        ticket_id: session.ticket_id,
        creator: { id: session.creator_id, name: session.creator&.display_name },
        occurred_on: session.occurred_on&.iso8601,
        duration_minutes: session.duration,
        description: session.description,
        customer_description: session.customer_description,
        billed: session.billed?,
        billed_at: session.billed_at&.iso8601,
        created_at: session.created_at.iso8601
      }
    end
  end
end
