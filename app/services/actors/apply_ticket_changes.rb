# frozen_string_literal: true

# Tier-1 actor: applies a list of changes to a set of tickets, one ticket at a
# time through the model, and records the run (doc/ticket_bulk_edit_plan.md,
# D13: ONE actor for one ticket and for many; a single ticket is a set of
# one). The change objects come from Tickets::Changes, the ticket ids from
# Tickets::BulkSelection.
#
# What the count changes, as a rule of this actor: with one ticket the
# activity chain notifies as it does today (the followers get "Status von
# #102 geändert" with its link); with several, every ticket's activity says
# skip_notifications and carries the run's id, and ONE run
# activity on the project is the event that notifies (D4, D12).
#
# With one ticket, a write that fails is the failure of the call: the board
# and the comment form get a failure result and no run is kept, because
# nothing was changed. With several, the failed ticket is named and the
# others commit (29a). The two single-ticket callers are
# TicketsController#update_kanban_attribute (board drag, sends clear for the
# unset column) and PostsController#handle_ticket_status_change (status while
# commenting, best effort).
#
# The rows are locked for the write (FOR UPDATE, in id order, so two runs on
# the same tickets queue instead of deadlocking) and the stock digests the
# panel showed are compared under that lock: a changed stock refuses before
# anything is written (D11). Each ticket then runs in its own savepoint: a
# ticket that cannot take the change is named in the results and the others
# commit (29a: partial results are named, never a silent success). The
# previous values go into the run record for "Rückgängig". The savepoint
# and the per-ticket rescue live in Tickets::ChangeApplier, so this actor
# keeps the contract (the failure mapping stays in BaseActor).
module Actors
  class ApplyTicketChanges < BaseActor
    attr_reader :run

    def initialize(project:, ticket_ids:, changes:, current_user:, expected_stock: {}, name_mode: nil)
      super()
      @project = project
      @ticket_ids = Array(ticket_ids).map(&:to_s).uniq
      @changes_params = changes
      @current_user = current_user
      @expected_stock = (expected_stock || {}).to_h.transform_keys(&:to_s)
      @name_mode = name_mode || User::PreferenceStore::NAME_DISPLAY_DEFAULT
    end

    def record
      @run
    end

    def perform
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.empty'), code: :empty) if @ticket_ids.empty?

      @changes = build_changes
      tickets = lock_tickets
      check_stock!(tickets)

      @run = TicketBulkRun.create!(organisation: @project.organisation, project: @project, user: @current_user,
                                   change_list: @changes.map(&:to_h))
      results = tickets.to_h { |ticket| [ticket.id, apply_to(ticket)] }
      @run.update!(results: results,
                   changed_count: results.count { |_id, result| result['ok'] },
                   failed_count: results.count { |_id, result| !result['ok'] })
      if !bulk? && @run.failed_count.positive?
        # One ticket: the failure of the write is the failure of the call, and
        # its code travels, so the board can say why it put the card back
        # ("required": a clear the ticket's definition refuses, S8 of
        # doc/kanban_ticket_als_bahn_plan.md). A model validation stays the
        # generic failure it was.
        code = results.values.first['error'].to_s
        code = 'validation_failed' if code.blank? || code == 'invalid'
        raise ActorError.new(I18n.t("views.organisations.tickets.bulk.errors.#{code}",
                                    default: I18n.t('views.organisations.tickets.bulk.errors.validation_failed')),
                             code: code.to_sym)
      end
      @project.track_tickets_bulk_changed(@run, describe: describe) if bulk? && @run.changed_count.positive?
      @run
    end

    private

    attr_reader :current_user

    def bulk?
      @ticket_ids.size > 1
    end

    def catalogue
      @catalogue ||= Tickets::BulkFields.for(project: @project, user: current_user, name_mode: @name_mode,
                                             ticket_ids: @ticket_ids)
    end

    def build_changes
      Tickets::Changes.build(@changes_params, catalogue: catalogue)
    rescue Tickets::Changes::Invalid => e
      raise ActorError.new(e.translated, code: e.code)
    end

    def lock_tickets
      tickets = @project.tickets.where(id: @ticket_ids).order(:id).lock('FOR UPDATE').to_a
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.outside_scope'), code: :outside_scope) if tickets.size != @ticket_ids.size

      tickets
    end

    # The stock the reader decided on, per changed field, against the stock
    # under the lock. Only fields the panel sent a digest for are compared.
    def check_stock!(tickets)
      return if @expected_stock.empty?

      fields = catalogue.select { |field| @expected_stock.key?(field.key) }
      return if fields.empty?

      summary = Tickets::BulkSummary.call(project: @project, ticket_ids: tickets.map(&:id), fields: fields)
      changed = fields.any? { |field| summary.dig(:fields, field.key, :digest) != @expected_stock[field.key] }
      raise ActorError.new(I18n.t('views.organisations.tickets.bulk.errors.stock_changed'), code: :stock_changed) if changed
    end

    # One ticket, its own savepoint, its line of the run: Tickets::ChangeApplier.
    def apply_to(ticket)
      Tickets::ChangeApplier.call(ticket: ticket, changes: @changes, current_user: @current_user,
                                  activity_context: activity_context)
    end

    def activity_context
      return { 'bulk_run_id' => @run.id } unless bulk?

      { 'bulk_run_id' => @run.id, 'bulk_run_member' => true, 'skip_notifications' => true }
    end

    def describe
      @changes.map(&:describe)
    end
  end
end
