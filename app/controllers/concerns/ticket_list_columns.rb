# frozen_string_literal: true

# The columns of the ticket list for an action that re-renders a row or the
# list outside TicketsController#index: a saved ticket, a comment written,
# edited or deleted (doc/spaltenwahl_plan.md, S1). One method for what the
# two controllers used to compute six times by hand. The folder comes
# through the policy scope, as on the index.
#
# Since the selection column (doc/ticket_bulk_edit_plan.md, slice 1) the
# same two controllers also answer whether the reader may tick rows: the row
# partial asks for every row, so the answer is kept for the request here, in
# the controller, where a memo belongs (helpers keep no instance variables).
module TicketListColumns
  extend ActiveSupport::Concern

  included do
    helper_method :ticket_list_selectable?, :ticket_list_row_streams, :ticket_list_parent_streams
  end

  private

  # Whether this reader may tick rows in the ticket list: the box column only
  # for readers with write access on the project's tickets (D3).
  def ticket_list_selectable?(project)
    return @ticket_list_selectable if defined?(@ticket_list_selectable)

    @ticket_list_selectable = project.present? && policy(project).area_access?(:tickets, :write)
  end

  def ticket_list_columns(project)
    view_configuration = ViewConfiguration.for_user_project(current_user, project, 'tickets')
    folder = policy_scope(SmartFolder).find_by(id: params[:smart_folder_id]) if params[:smart_folder_id].present?
    Tickets::ResolveColumns.call(view_configuration: view_configuration, smart_folder: folder)
  end

  # The streams that redraw a ticket's row in the list after a write to it:
  # the desktop row and the mobile row, each from its own partial, so the
  # answer does not hang on which viewport the request was taken for. Plus the
  # pieces of its parent's row that count the children (below). One method
  # for what three controllers and a template wrote out by hand six times, in
  # two shapes.
  def ticket_list_row_streams(ticket, selected_ticket: ticket, columns: nil)
    [
      turbo_stream.replace_all("tr[data-ticket-id='#{ticket.id}']",
                               partial: 'organisations/tickets/ticket_row',
                               locals: { ticket: ticket, selected_ticket: selected_ticket, project: ticket.project,
                                         columns: columns || ticket_list_columns(ticket.project) }),
      turbo_stream.replace_all(".mobile-ticket-row[data-ticket-id='#{ticket.id}']",
                               partial: 'organisations/tickets/ticket_row_mobile',
                               locals: { ticket: ticket, project: ticket.project })
    ] + ticket_list_parent_streams(ticket)
  end

  # A sub-ticket added, deleted, moved or with a new status changes its
  # parent's "1/3" - and the parent it had before a move. What goes out is
  # the CELL and the item under the title of each column counted from the
  # children (ViewConfiguration::CHILDREN_COLUMN_KEYS), never the parent's
  # whole row: a whole row needs what only the list knows - the active view's
  # columns (no form in the detail carries the folder) and the unread counts
  # of the index - and lost both (second review of #927). A page without the
  # column has no such cell, and the update finds no target.
  # Used alone where the child has no row of its own to redraw (the quick-add,
  # a delete).
  def ticket_list_parent_streams(ticket)
    parent_ids = [ticket.parent_id, ticket.parent_id_before_last_save].compact.uniq
    return [] if parent_ids.empty?

    # One view for every parent, counted in one pass the way the list counts a
    # page: the controller's turbo_stream builds a fresh view per call, and
    # each would count its parent on its own.
    parents = ticket.project.tickets.where(id: parent_ids).to_a
    view = view_context
    view.register_ticket_count_page(parents)
    builder = Turbo::Streams::TagBuilder.new(view)
    parents.flat_map do |parent|
      row = "tr[data-ticket-id='#{parent.id}']"
      ViewConfiguration::CHILDREN_COLUMN_KEYS.flat_map do |key|
        column = { key: key }
        # action_all(:update, ...) is what TagBuilder#update_all calls. Named
        # update_all, Brakeman takes it for ActiveRecord's and the selector
        # string for SQL; the selector holds two ids and a constant key.
        [builder.action_all(:update, "#{row} td[data-column='#{key}']", view.ticket_column_cell(parent, column).to_s),
         builder.action_all(:update, "#{row} .ticket-meta__item[data-meta-column='#{key}']",
                            view.ticket_column_meta_text(parent, column).to_s)]
      end
    end
  end
end
