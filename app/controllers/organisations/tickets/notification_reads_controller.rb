# frozen_string_literal: true

module Organisations
  module Tickets
    # A ticket view that stayed open for a moment marks the viewer's notifications
    # about that ticket as read (Notifications::MarkTicketRead). The request comes
    # from pane_mark_read_delay_controller, the same 5-second rule as the inbox pane.
    #
    # Deliberately lean, like Tickets::SubtasksController: the fat TicketsController
    # loads the whole list before every action. And not ProjectController, whose
    # gate reads an action named `update` as a ticket write: marking one's own
    # notifications is reading, so a viewer with read access may do it.
    class NotificationReadsController < Organisations::BaseController
      before_action :set_ticket

      # PATCH /org/:organisation_id/projects/:project_id/tickets/:ticket_id/notification_read
      def update
        authorize @ticket, :show?

        Notifications::MarkTicketRead.broadcast(
          Notifications::MarkTicketRead.call(user: current_user, ticket: @ticket)
        )
        @unread_count = current_user.unread_notifications_count(current_organisation)
      end

      private

      def set_ticket
        @ticket = Project.find(params[:project_id]).tickets.find(params[:ticket_id])
      end
    end
  end
end
