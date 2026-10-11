# frozen_string_literal: true

# The ticket's assignees, through TicketAssignmentSync: it inserts and deletes
# in sets, keeps the subscriptions in step and writes the assigned/unassigned
# activities, with the write's activity context threaded in.
#
# Entry point: apply
module Tickets
  module Changes
    class AddRemoveAssignees < AddRemoveBase
      private

      def current(ticket)
        ticket.ticket_assignments.pluck(:user_id).map(&:to_s)
      end

      # A person the run took off who may not be assigned any more (deactivated,
      # or without access) stays off; whoever is assigned still stays.
      def restorable(ticket, values)
        values & ticket.assignable_user_ids(values).map(&:to_s)
      end

      def write(ticket, values, before)
        assignable = ticket.assignable_user_ids(values).map(&:to_s)
        raise NotApplicable.with(:user_not_assignable) if (values - assignable).any?

        TicketAssignmentSync.call(ticket: ticket, assignee_ids: values, is_new_ticket: false,
                                  extra_activity_parameters: (ticket.activity_context || {}).to_h)
        ticket.touch if values.sort != before.sort
      end
    end
  end
end
