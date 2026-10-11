# frozen_string_literal: true

module SmartFolders
  module Filters
    # Filter for ticket assignments (EXISTS subquery on ticket_assignments)
    class AssigneeFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, _item_type)
        return query unless query.model == Ticket

        user_id = rule.value

        case rule.operator
        when EQUALS
          return query.none if user_id.blank?

          query.where(assignment_exists_subquery(user_id))
        when NOT_EQUALS
          return query if user_id.blank?

          query.where(assignment_exists_subquery(user_id).not)
        else
          Rails.logger.warn "Unsupported assignee operator '#{rule.operator}' for rule #{rule.id}"
          query
        end
      end

      private

      def assignment_exists_subquery(user_id)
        assignments = TicketAssignment.arel_table
        tickets = Ticket.arel_table

        assignments.project(1)
                   .where(assignments[:ticket_id].eq(tickets[:id]))
                   .where(assignments[:user_id].eq(user_id))
                   .exists
      end
    end
  end
end
