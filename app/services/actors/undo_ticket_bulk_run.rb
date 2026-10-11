# frozen_string_literal: true

# Tier-1 actor: takes a bulk run back (doc/ticket_bulk_edit_plan.md, D8).
# Reads the previous values from the run record and restores them through
# the same change classes, one ticket at a time in its own savepoint. It never
# overwrites blindly: a ticket that no longer carries what the run wrote
# (somebody changed it since) is left alone and named in the results. The
# undo is a run of its own, so the result line and the feed can name it, and
# the original is marked undone.
module Actors
  class UndoTicketBulkRun < BaseActor
    def initialize(run:, current_user:)
      super()
      @original = run
      @current_user = current_user
    end

    def record
      @undo
    end

    def perform
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.not_undoable'), code: :not_undoable) unless @original.undoable_by?(@current_user)

      changes = build_changes
      ids = @original.ok_ticket_ids
      tickets = @original.project.tickets.where(id: ids).order(:id).lock('FOR UPDATE').to_a

      @undo = TicketBulkRun.create!(organisation: @original.organisation, project: @original.project, user: @current_user,
                                    undo_of: @original, change_list: @original.change_list)
      results = tickets.to_h { |ticket| [ticket.id, undo_on(ticket, changes)] }
      @undo.update!(results: results,
                    changed_count: results.count { |_id, result| result['ok'] },
                    failed_count: results.count { |_id, result| !result['ok'] })
      @original.update!(undone_at: Time.current)
      @original.project.track_tickets_bulk_undone(@undo, describe: changes.map(&:describe)) if tickets.size > 1 && @undo.changed_count.positive?
      @undo
    end

    private

    attr_reader :current_user

    # A change list the catalogue refuses is the failure of the call, with its
    # code, as in ApplyTicketChanges; never an unexpected error.
    def build_changes
      Tickets::Changes.build(@original.change_list, catalogue: catalogue)
    rescue Tickets::Changes::Invalid => e
      raise ActorError.new(e.translated, code: e.code)
    end

    def catalogue
      @catalogue ||= Tickets::BulkFields.for_run(run: @original, user: current_user)
    end

    def undo_on(ticket, changes)
      return { 'ok' => false, 'number' => ticket.number, 'error' => 'changed_since' } unless changes.all? { |change| change.still_applied?(ticket) }

      Tickets::ChangeApplier.call(ticket: ticket, changes: changes, current_user: @current_user,
                                  activity_context: activity_context, restore_from: @original.before_for(ticket.id))
    end

    def activity_context
      return { 'bulk_run_id' => @undo.id, 'undo_of' => @original.id } unless @original.ok_ticket_ids.size > 1

      { 'bulk_run_id' => @undo.id, 'undo_of' => @original.id, 'bulk_run_member' => true, 'skip_notifications' => true }
    end
  end
end
