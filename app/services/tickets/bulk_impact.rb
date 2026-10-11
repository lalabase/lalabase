# frozen_string_literal: true

# What a move or a delete of the selected tickets takes with it, counted from
# the live selection for the confirmation (doc/ticket_bulk_edit_plan.md, D15
# and slice 7): the comments and attachments that go, the time sessions that
# keep their booking but lose the ticket (dependent: :nullify), the sub-tickets
# outside the selection that become standalone; for a move, the assignments
# and subscriptions the target cannot keep and the tickets a hierarchy keeps
# here. Numbers only: the dialog names them, the actors decide.
#
# Entry point: call
module Tickets
  class BulkImpact
    def self.call(project:, ticket_ids:, target_project: nil)
      new(project: project, ticket_ids: ticket_ids, target_project: target_project).call
    end

    def initialize(project:, ticket_ids:, target_project: nil)
      @project = project
      @ticket_ids = Array(ticket_ids).map(&:to_s).uniq
      @target_project = target_project
    end

    def call
      impact = {
        count: @ticket_ids.size,
        posts: Post.where(ticket_id: @ticket_ids).count,
        documents: TicketDocument.where(ticket_id: @ticket_ids).count,
        time_sessions: TimeSession.where(ticket_id: @ticket_ids).count,
        children: Ticket.where(parent_id: @ticket_ids).where.not(id: @ticket_ids).count,
        hierarchy: hierarchy_count
      }
      impact[:move] = move_impact if @target_project
      impact
    end

    private

    # Tickets the mover refuses: a parent or a child (Tickets::Mover keeps a
    # hierarchy within one project).
    def hierarchy_count
      tickets = Ticket.where(id: @ticket_ids)
      tickets.where.not(parent_id: nil).or(tickets.where(id: Ticket.where(parent_id: @ticket_ids).select(:parent_id))).count
    end

    def move_impact
      target_users = @target_project.users_with_access(:read, :tickets).pluck(:id)
      {
        lost_assignments: TicketAssignment.where(ticket_id: @ticket_ids).where.not(user_id: target_users).count,
        lost_subscriptions: NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: @ticket_ids)
                                                    .where.not(user_id: target_users).count
      }
    end
  end
end
