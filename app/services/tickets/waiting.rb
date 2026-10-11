# frozen_string_literal: true

# The one owner of "waits" and "holds others up" (doc/ticket_relations_plan.md, revision 4,
# §5). The header, the list column, the board, the phone row, both filter systems and the API
# all ask here; seven hand-built versions would drift apart.
#
# A ticket WAITS when it is not done itself and at least one ticket that is not done points at
# it with a waiting edge (TicketRelation::WAITING_TYPES). A ticket HOLDS OTHERS UP when it is
# not done and at least one ticket that is not done waits because of it. Counted are tickets,
# not edges: "A blocks B" plus "A precedes B" is one ticket B waits on. delay_days plays no part.
#
# "Done" is judged per ticket by its OWN project (TicketAttributeDefinition
# .closed_status_values_by_project), at both ends of an edge: the same status name may mean
# done in one project and open in another. The projects come from the tickets involved, never
# from the caller: a list of project B shows blockers in X and Y. No status, or a project
# without a done value, means not done.
#
# Read rights play no part: whether a ticket waits is a fact about that ticket. Hiding what a
# reader may not see is the display's job (plan §4).
#
# Entry point: waiting, blocking, counts_for, for, open_ids
module Tickets
  class Waiting
    EMPTY_COUNTS = { waiting_on: 0, blocking: 0 }.freeze

    # The table names open_sql may qualify: the ticket asked about, and the ticket at the other
    # end of an edge. A fixed list, so no caller can hand in SQL.
    TABLES = %w[tickets blocker waiter].freeze

    class << self
      # The tickets of `scope` that wait. Keeps the scope's order, limit and select.
      def waiting(scope)
        closed = closed_values_around(ticket_ids_of(scope))
        scope.where(open_sql('tickets', closed)).where(edges_into_tickets(closed).arel.exists)
      end

      # The tickets of `scope` that hold others up.
      def blocking(scope)
        closed = closed_values_around(ticket_ids_of(scope))
        scope.where(open_sql('tickets', closed)).where(edges_out_of_tickets(closed).arel.exists)
      end

      # { id => { waiting_on:, blocking: } } for every id given, zero where nothing applies.
      # One preparation query (the done values of every project involved) and one aggregation,
      # whatever the number of tickets.
      def counts_for(ticket_ids)
        ids = ids_only(ticket_ids)
        return {} if ids.empty?

        closed = closed_values_around(ids)
        waiting_on = edges_into_tickets(closed).select('COUNT(DISTINCT ticket_relations.source_ticket_id)')
        blocking = edges_out_of_tickets(closed).select('COUNT(DISTINCT ticket_relations.target_ticket_id)')
        rows = Ticket.where(id: ids).where(open_sql('tickets', closed))
                     .pluck(:id, Arel::Nodes::Grouping.new(waiting_on.arel), Arel::Nodes::Grouping.new(blocking.arel))
        counts = rows.to_h { |id, waiting_count, blocking_count| [id, { waiting_on: waiting_count, blocking: blocking_count }] }
        ids.index_with { |id| counts.fetch(id, EMPTY_COUNTS) }
      end

      # The open tickets `ticket` waits on, by number, then id: stable, and across projects the
      # numbers interleave (Y#1 before X#2). A display that shows project and number groups
      # them itself. Empty when `ticket` is done itself.
      def for(ticket)
        closed = closed_values_around([ticket.id])
        Ticket.where(open_sql('tickets', closed))
              .where(edges_out_of_tickets(closed).where(target_ticket_id: ticket.id).arel.exists)
              .order(:number, :id)
      end

      # The ids among `ticket_ids` of tickets that are not done, each by its own project's rules.
      # For a display that marks what is done (the relations section) by the same rule as the
      # waiting state, so a blocker never reads as done in one place and as open in the other.
      # One preparation query and one lookup.
      def open_ids(ticket_ids)
        ids = ids_only(ticket_ids)
        return [] if ids.empty?

        tickets = Ticket.where(id: ids)
        closed = TicketAttributeDefinition.closed_status_values_by_project(tickets.select(:project_id))
        tickets.where(open_sql('tickets', closed)).pluck(:id)
      end

      private

      # Every candidate of the scope: without limit and offset, since the page is cut AFTER the
      # waiting condition. includes and eager_load stay, a condition on their table needs the
      # join (review step 2, 30.09.2026).
      def ticket_ids_of(scope)
        scope.unscope(:select, :order, :limit, :offset, :preload).select(:id)
      end

      # Ids only: records as keys would find nothing and answer zero for every ticket.
      def ids_only(ticket_ids)
        ids = ticket_ids.is_a?(ActiveRecord::Relation) ? [ticket_ids] : Array(ticket_ids).compact.uniq
        raise ArgumentError, 'takes ticket ids, not records or relations' unless ids.all?(String)

        ids
      end

      # The done values of every project a ticket at either end of the waiting edges touching
      # `ticket_ids` lives in. One query: the project ids are a subquery.
      def closed_values_around(ticket_ids)
        edges = TicketRelation.waiting_edges
        involved = Ticket.where(id: ticket_ids)
                         .or(Ticket.where(id: edges.where(target_ticket_id: ticket_ids).select(:source_ticket_id)))
                         .or(Ticket.where(id: edges.where(source_ticket_id: ticket_ids).select(:target_ticket_id)))
        TicketAttributeDefinition.closed_status_values_by_project(involved.select(:project_id))
      end

      # Waiting edges into the outer `tickets` row whose source is not done.
      def edges_into_tickets(closed)
        TicketRelation.waiting_edges
                      .joins('INNER JOIN tickets blocker ON blocker.id = ticket_relations.source_ticket_id')
                      .where('ticket_relations.target_ticket_id = tickets.id')
                      .where(open_sql('blocker', closed))
      end

      # Waiting edges out of the outer `tickets` row whose target is not done.
      def edges_out_of_tickets(closed)
        TicketRelation.waiting_edges
                      .joins('INNER JOIN tickets waiter ON waiter.id = ticket_relations.target_ticket_id')
                      .where('ticket_relations.source_ticket_id = tickets.id')
                      .where(open_sql('waiter', closed))
      end

      # SQL that holds when the ticket in `table` is not done by its own project's rules:
      # its (project, status) pair is not among the done pairs. NOT EXISTS rather than NOT IN,
      # so a ticket without a status (NULL) counts as open instead of vanishing.
      #
      # Positional binds only. The status values come from project configuration, and a named
      # bind (:name) would also be replaced inside their quoted text (the SQL injection of
      # #889). Never pass the result on together with named binds.
      def open_sql(table, closed)
        raise ArgumentError, "unknown table #{table.inspect}" unless TABLES.include?(table)

        pairs = closed.flat_map { |project_id, values| values.map { |value| [project_id, value] } }
        return 'TRUE' if pairs.empty?

        rows = Array.new(pairs.size, '(CAST(? AS uuid), CAST(? AS text))').join(', ')
        ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, *pairs.flatten])
          NOT EXISTS (SELECT 1 FROM (VALUES #{rows}) AS done_status(project_id, status)
                      WHERE done_status.project_id = #{table}.project_id
                        AND done_status.status = LOWER(#{table}.custom_attributes->>'status'))
        SQL
      end
    end
  end
end
