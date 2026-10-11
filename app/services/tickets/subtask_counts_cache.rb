# frozen_string_literal: true

# One request's answers about how many sub-tickets each ticket has, and how many
# of them are done.
#
# Entry point: fetch
#
# The twin of TimeSessions::SubjectTotalsCache, for the "Subs" column: a list
# registers its page (Tickets::LazyPagePreload) and the first read preloads it,
# two grouped counts per project. A row the preload never saw - the single-row
# turbo-stream re-render after a save - is counted on its own. A miss costs a
# query, never a zero: "0/0" on a parent with three children is a wrong number
# that looks like a right one.
#
# "Done" is the project's own word for it (the is_completed/is_closed system
# functions, TicketAttributeDefinition.closed_status_values_for), the same rule
# as Ticket#children_progress on the detail page. Children share their parent's
# project (Ticket#parent_loadable_and_same_project), so one project's values
# answer for every child of a ticket.
module Tickets
  class SubtaskCountsCache
    prepend LazyPagePreload

    EMPTY_ENTRY = { done: 0, total: 0 }.freeze

    def initialize
      @entries = {}
      @done_values = {}
    end

    # Fills the cache for a page. Returns self so a view can call it as a
    # statement.
    def preload(tickets)
      tickets.group_by(&:project_id).each do |project_id, project_tickets|
        ids = project_tickets.map(&:id)
        counts = count(ids, project_id)
        ids.each { |id| @entries[id] = counts.fetch(id, EMPTY_ENTRY) }
      end
      self
    end

    # An unsaved ticket has no children; asked by its id, nil, it would count every top-level
    # ticket of the tenant.
    def fetch(ticket)
      return EMPTY_ENTRY if ticket.id.nil?

      @entries[ticket.id] ||= count([ticket.id], ticket.project_id).fetch(ticket.id, EMPTY_ENTRY)
    end

    private

    # For Tickets::LazyPagePreload.
    def answered?(ticket_id)
      @entries.key?(ticket_id)
    end

    def count(parent_ids, project_id)
      children = Ticket.where(parent_id: parent_ids)
      totals = children.group(:parent_id).count
      done = children.with_status_values(done_values_for(project_id)).group(:parent_id).count
      totals.to_h { |parent_id, total| [parent_id, { done: done.fetch(parent_id, 0), total: total }] }
    end

    # Memoized per project: a page asks once, and every stray row after it.
    def done_values_for(project_id)
      @done_values[project_id] ||= TicketAttributeDefinition.closed_status_values_for([project_id])
    end
  end
end
