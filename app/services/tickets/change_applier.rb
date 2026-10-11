# frozen_string_literal: true

# Applies (or restores) the changes of a bulk run to ONE ticket inside its
# own savepoint and answers with the ticket's line of the run record
# (doc/ticket_bulk_edit_plan.md, slice 6). A ticket that cannot take the
# change rolls back its savepoint and is named with a code; the actor, which is
# the loop around this, commits the others. The rescue lives here and not in
# the actor on purpose: the actor's contract keeps the failure mapping in
# BaseActor#with_error_mapping, and this is not a failure of the run but the
# result of one ticket.
#
# Entry point: call
module Tickets
  class ChangeApplier
    def self.call(ticket:, changes:, current_user:, activity_context:, restore_from: nil)
      new(ticket: ticket, changes: changes, current_user: current_user,
          activity_context: activity_context, restore_from: restore_from).call
    end

    # restore_from: the previous values of this ticket from the original run;
    # given, the changes are restored instead of applied.
    def initialize(ticket:, changes:, current_user:, activity_context:, restore_from: nil)
      @ticket = ticket
      @changes = changes
      @current_user = current_user
      @activity_context = activity_context
      @restore_from = restore_from
    end

    def call
      @ticket.updater = @current_user
      @ticket.activity_context = @activity_context
      before = {}
      Ticket.transaction(requires_new: true) do
        @changes.each do |change|
          if @restore_from
            change.restore(@ticket, @restore_from[change.key])
            before[change.key] = @restore_from[change.key]
          else
            before[change.key] = change.apply(@ticket)
          end
        end
      end
      { 'ok' => true, 'number' => @ticket.number, 'before' => before }
    rescue ActiveRecord::RecordInvalid
      { 'ok' => false, 'number' => @ticket.number, 'error' => 'invalid' }
    rescue Tickets::Changes::NotApplicable => e
      { 'ok' => false, 'number' => @ticket.number, 'error' => e.code.to_s }
    end
  end
end
