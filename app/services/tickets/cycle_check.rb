# frozen_string_literal: true

# Answers whether `to` can already be reached from `from` over one fixed set of edges
# (doc/ticket_relations_plan.md, revision 4, §3.2). For a new edge A -> B the caller asks
# whether B already reaches A: if it does, the new edge would close a cycle.
#
# The edge set is a name from EDGES, never SQL from outside: each entry is a relation that
# selects from_id and to_id, and its values are quoted by ActiveRecord. The ticket ids travel
# as real positional binds ($1, $2).
#
# The recursive part outputs the ticket id and nothing else (no depth, no path). UNION then
# drops every id it has seen, so the query ends even on a cycle that is already in the data.
#
# Without a lock around it the answer is stale by the next statement: two writers could each
# find no cycle and together close one. Actors::CreateTicketRelation holds an advisory lock
# for the organisation across this check and its write.
module Tickets
  class CycleCheck
    # The sub-task hierarchy has no edge set here on purpose: a new ticket has no
    # descendants and a saved ticket's parent is fixed (Ticket#parent_unchanged), so no
    # parent link can close a cycle. Waiting relations are the only edges that can.
    EDGES = {
      waiting_relations: lambda {
        TicketRelation.waiting_edges.select('ticket_relations.source_ticket_id AS from_id',
                                            'ticket_relations.target_ticket_id AS to_id')
      }
    }.freeze

    def self.call(edges:, from:, to:)
      new(edges: edges, from: from, to: to).call
    end

    def initialize(edges:, from:, to:)
      @edges_sql = EDGES.fetch(edges).call.to_sql
      @from = from
      @to = to
    end

    def call
      ActiveRecord::Base.connection.select_value(<<~SQL.squish, self.class.name, [@from, @to])
        WITH RECURSIVE reachable(id) AS (
          SELECT edges.to_id FROM (#{@edges_sql}) AS edges WHERE edges.from_id = $1
          UNION
          SELECT edges.to_id FROM (#{@edges_sql}) AS edges JOIN reachable ON edges.from_id = reachable.id
        )
        SELECT EXISTS (SELECT 1 FROM reachable WHERE reachable.id = $2)
      SQL
    end
  end
end
