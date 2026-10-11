# frozen_string_literal: true

module Lalabase
  module Tools
    # Shared §9.2 payload: an ambiguous ticket number answers with a candidate
    # list (project, number, title), never an error — the model turns it into a
    # follow-up question the user answers with one click.
    # Entry point: payload
    #
    # ONE owner for the candidate row shape. Two tools resolve a number inside
    # an org-wide scope (GetTicket's direct address, SummarizeTimeSessions'
    # ticket filter); duplicating the shape would let their follow-up questions
    # drift apart. Callers keep their own limit constants (GetTicket pins its
    # MAX_CANDIDATES in specs) and their own rights filtering — this module only
    # shapes rows it is handed, it never widens them.
    module TicketCandidates
      DEFAULT_LIMIT = 10

      def self.payload(tickets, number, limit: DEFAULT_LIMIT)
        {
          ambiguous: true,
          number: number,
          candidates_total: tickets.size,
          candidates: tickets.first(limit).map { |ticket| row(ticket) }
        }
      end

      # Just enough to tell two same-numbered tickets apart — never the body.
      def self.row(ticket)
        {
          id: ticket.id,
          number: ticket.number,
          title: ticket.title,
          project: { id: ticket.project_id, name: ticket.project&.name }
        }
      end
    end
  end
end
