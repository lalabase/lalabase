# frozen_string_literal: true

# Deletes ONE ticket of a bulk run inside its own savepoint and answers with
# the ticket's line of the run record (doc/ticket_bulk_edit_plan.md, slice 7):
# the sibling of Tickets::ChangeApplier. A ticket that refuses to go (a
# callback aborts, a dependent cannot be removed) is named with a code; the
# actor, which is the loop around this, commits the others.
#
# Entry point: call
module Tickets
  class DestroyApplier
    def self.call(ticket:, current_user:, activity_context:)
      new(ticket: ticket, current_user: current_user, activity_context: activity_context).call
    end

    def initialize(ticket:, current_user:, activity_context:)
      @ticket = ticket
      @current_user = current_user
      @activity_context = activity_context
    end

    def call
      line = { 'number' => @ticket.number, 'title' => @ticket.title }
      @ticket.updater = @current_user
      @ticket.activity_context = @activity_context
      Ticket.transaction(requires_new: true) { @ticket.destroy! }
      line.merge('ok' => true)
    rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey
      line.merge('ok' => false, 'error' => 'not_deletable')
    end
  end
end
