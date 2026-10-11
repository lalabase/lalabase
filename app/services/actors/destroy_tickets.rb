# frozen_string_literal: true

# Tier-1 actor: deletes a set of tickets, one at a time through the model, and
# records the run (doc/ticket_bulk_edit_plan.md, D15 and slice 7). Every
# ticket keeps its own "deleted" activity (Trackable#track_deleted), marked
# as a member of the run and silent; the project gets ONE run activity that
# notifies the tickets' followers. The followers are read BEFORE the delete,
# because a ticket takes its subscriptions with it, and ride along in the
# run activity's parameters for the fanout. No undo (D15): what a ticket takes
# with it is gone; a trash for tickets is its own strand.
module Actors
  class DestroyTickets < BaseActor
    def initialize(project:, ticket_ids:, current_user:)
      super()
      @project = project
      @ticket_ids = Array(ticket_ids).map(&:to_s).uniq
      @current_user = current_user
    end

    def record
      @run
    end

    def perform
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.empty'), code: :empty) if @ticket_ids.empty?

      tickets = lock_tickets
      follower_ids = follower_ids_of(tickets)
      @run = TicketBulkRun.create!(organisation: @project.organisation, project: @project, user: @current_user,
                                   kind: TicketBulkRun::KIND_DELETE, change_list: [{ 'kind' => TicketBulkRun::KIND_DELETE }])
      results = tickets.to_h { |ticket| [ticket.id, destroy(ticket)] }
      @run.update!(results: results,
                   changed_count: results.count { |_id, result| result['ok'] },
                   failed_count: results.count { |_id, result| !result['ok'] })
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.result.reasons.not_deletable'), code: :not_deletable) if !bulk? && @run.failed_count.positive?

      if bulk? && @run.changed_count.positive?
        @project.track_tickets_bulk_deleted(@run, follower_ids: follower_ids,
                                                  describe: [I18n.t('views.organisations.tickets.bulk.describe.deleted')])
      end
      @run
    end

    private

    attr_reader :current_user

    def bulk?
      @ticket_ids.size > 1
    end

    def lock_tickets
      tickets = @project.tickets.where(id: @ticket_ids).order(:id).lock('FOR UPDATE').to_a
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.outside_scope'), code: :outside_scope) if tickets.size != @ticket_ids.size

      tickets
    end

    def follower_ids_of(tickets)
      NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: tickets.map(&:id), mode: :follow)
                              .distinct.pluck(:user_id)
    end

    # One ticket, its own savepoint, its line of the run. The rescue stays out
    # of the actor's own methods only in name: a ticket that refuses to go
    # (a callback aborts) is the result of one ticket, not of the run.
    def destroy(ticket)
      Tickets::DestroyApplier.call(ticket: ticket, current_user: @current_user, activity_context: activity_context)
    end

    def activity_context
      return { 'bulk_run_id' => @run.id } unless bulk?

      { 'bulk_run_id' => @run.id, 'bulk_run_member' => true, 'skip_notifications' => true }
    end
  end
end
