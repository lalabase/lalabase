# frozen_string_literal: true

# Moves ONE ticket of a bulk run and answers with the ticket's line of the run
# record (doc/ticket_bulk_edit_plan.md, slice 7): the sibling of
# Tickets::ChangeApplier. A ticket the mover refuses (a hierarchy, the number
# race) or that cannot be saved is named with a code; the actor, which is the
# loop around this, commits the others. The rescue lives here and not in the
# actor on purpose (the actor's contract keeps the failure mapping in
# BaseActor#with_error_mapping).
#
# Entry point: call
module Tickets
  class MoveApplier
    def self.call(ticket:, target_project:, current_user:, activity_context:)
      new(ticket: ticket, target_project: target_project, current_user: current_user,
          activity_context: activity_context).call
    end

    def initialize(ticket:, target_project:, current_user:, activity_context:)
      @ticket = ticket
      @target_project = target_project
      @current_user = current_user
      @activity_context = activity_context
    end

    def call
      number = @ticket.number
      Ticket.transaction(requires_new: true) do
        Tickets::Mover.call(ticket: @ticket, target_project: @target_project, current_user: @current_user,
                            activity_context: @activity_context)
      end
      { 'ok' => true, 'number' => number, 'new_number' => @ticket.number }
    rescue Tickets::Mover::Refused => e
      { 'ok' => false, 'number' => number, 'error' => e.code.to_s }
    rescue ActiveRecord::RecordInvalid
      { 'ok' => false, 'number' => number, 'error' => 'invalid' }
    end
  end
end
