# frozen_string_literal: true

# Answers which tickets lie above a ticket in its sub-task tree: its ancestors, from the
# root down to the direct parent, each an Ancestor value with id, number and project_id
# (enough to link it). A ticket without parent has none.
#
# One query, a recursive CTE, because sub-tasks nest to any depth: walking parent by parent
# from Ruby would cost one query per level, on every ticket page that shows the trail.
#
# It ends on bad data. Every row carries the path of ids walked so far, and a step that would
# visit an id already on the path is not taken, so a cycle written past the model (A -> B ->
# A, or a ticket that is its own parent) stops after each ticket was seen once. Every step
# stays in the ticket's own project and organisation: a parent_id that points elsewhere ends
# the walk there instead of disclosing the foreign ticket or what lies above it.
#
# All values travel as positional binds ($1, $2, $3), none is interpolated.
module Tickets
  class Ancestry
    # A value, not a Ticket: a Ticket loaded with three columns trips its own callbacks
    # (CustomAttributable reads custom_attributes on initialize). to_param is the id, so a
    # route helper takes it like a ticket.
    Ancestor = Data.define(:id, :number, :project_id) do
      def to_param = id
    end

    def self.call(ticket:)
      new(ticket: ticket).call
    end

    def initialize(ticket:)
      @ticket = ticket
    end

    def call
      return [] if @ticket.parent_id.nil?

      rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish, self.class.name, binds)
        WITH RECURSIVE ancestors(id, number, project_id, parent_id, depth, path) AS (
          SELECT tickets.id, tickets.number, tickets.project_id, tickets.parent_id, 0, ARRAY[tickets.id]
          FROM tickets
          WHERE tickets.id = $1 AND tickets.project_id = $2 AND tickets.organisation_id = $3
          UNION
          SELECT parents.id, parents.number, parents.project_id, parents.parent_id,
                 ancestors.depth + 1, ancestors.path || parents.id
          FROM tickets AS parents
          JOIN ancestors ON parents.id = ancestors.parent_id
          WHERE parents.project_id = $2 AND parents.organisation_id = $3
            AND NOT parents.id = ANY(ancestors.path)
        )
        SELECT id, number, project_id FROM ancestors WHERE depth > 0 ORDER BY depth DESC
      SQL

      rows.map { |row| Ancestor.new(**row.symbolize_keys) }
    end

    private

    def binds
      [@ticket.id, @ticket.project_id, @ticket.organisation_id]
    end
  end
end
