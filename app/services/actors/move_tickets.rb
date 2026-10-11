# frozen_string_literal: true

# Tier-1 actor: moves a set of tickets into another project, one ticket at a
# time through Tickets::Mover, and records the run (doc/ticket_bulk_edit_plan.md,
# slice 7). The sibling of Actors::ApplyTicketChanges with the same rules: the
# rows are locked in id order, every ticket runs in its own savepoint
# (Tickets::MoveApplier) and a ticket the mover refuses (a hierarchy, the
# number race) is named in the results while the others commit. With several
# tickets the per-ticket activities carry the run and skip notifications, the
# source project gets ONE run activity that notifies the followers, the
# target project one that only tells its feed. No undo: a move assigns new
# numbers, undoing would be a second move.
module Actors
  class MoveTickets < BaseActor
    def initialize(project:, ticket_ids:, target_project:, current_user:)
      super()
      @project = project
      @ticket_ids = Array(ticket_ids).map(&:to_s).uniq
      @target_project = target_project
      @current_user = current_user
    end

    def record
      @run
    end

    def perform
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.empty'), code: :empty) if @ticket_ids.empty?
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.target_project'), code: :target_project) if @target_project.nil? || @target_project.id == @project.id

      tickets = lock_tickets
      @run = TicketBulkRun.create!(organisation: @project.organisation, project: @project, user: @current_user,
                                   kind: TicketBulkRun::KIND_MOVE, change_list: [change_entry])
      results = tickets.to_h { |ticket| [ticket.id, move(ticket)] }
      @run.update!(results: results,
                   changed_count: results.count { |_id, result| result['ok'] },
                   failed_count: results.count { |_id, result| !result['ok'] })
      if !bulk? && @run.failed_count.positive?
        failure = results.values.first
        raise ActorError.new(I18n.t("views.organisations.tickets.bulk.result.reasons.#{failure['error']}",
                                    default: failure['error'].to_s), code: failure['error'].to_sym)
      end
      track_run if bulk? && @run.changed_count.positive?
      @run
    end

    private

    attr_reader :current_user

    def bulk?
      @ticket_ids.size > 1
    end

    def change_entry
      { 'kind' => TicketBulkRun::KIND_MOVE, 'target_project_id' => @target_project.id, 'target_project_name' => @target_project.name }
    end

    def lock_tickets
      tickets = @project.tickets.where(id: @ticket_ids).order(:id).lock('FOR UPDATE').to_a
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.outside_scope'), code: :outside_scope) if tickets.size != @ticket_ids.size

      tickets
    end

    def move(ticket)
      Tickets::MoveApplier.call(ticket: ticket, target_project: @target_project, current_user: @current_user,
                                activity_context: activity_context)
    end

    def activity_context
      return { 'bulk_run_id' => @run.id } unless bulk?

      { 'bulk_run_id' => @run.id, 'bulk_run_member' => true, 'skip_notifications' => true }
    end

    def track_run
      describe = I18n.t('views.organisations.tickets.bulk.describe.moved', project: @target_project.name)
      @project.track_tickets_bulk_moved(@run, target: @target_project, describe: [describe])
      @target_project.track_tickets_bulk_moved_in(@run, source: @project, describe: [describe])
    end
  end
end
