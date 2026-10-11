# frozen_string_literal: true

# One request's answers about how many open tickets each ticket waits on, for the "Wartet"
# column, the board's card and the phone row (doc/ticket_relations_plan.md, revision 4, §8.3,
# §8.4).
#
# Entry point: fetch
#
# The twin of Tickets::SubtaskCountsCache: a list, a board or a phone page registers its tickets
# (Tickets::LazyPagePreload), and the first read counts them in one Tickets::Waiting.counts_for
# (a fixed number of queries, whatever the length). A row or card the preload never saw - the
# single-row turbo-stream re-render after a save - counts itself. A miss costs two queries,
# never a zero: a missing hourglass on a waiting ticket looks like a right answer.
#
# The numbers are Tickets::Waiting's alone: tickets, not edges; "done" per project at both ends;
# every open blocker, readable or not (plan §4). Nothing here names another ticket.
module Tickets
  class WaitingCountsCache
    prepend LazyPagePreload

    def initialize
      @entries = {}
    end

    # Fills the cache for a page. Returns self so a view can call it as a statement.
    def preload(tickets)
      @entries.merge!(Waiting.counts_for(tickets.map(&:id)))
      self
    end

    # The number of open tickets `ticket` waits on; 0 when it waits on none or is done itself.
    # An unsaved ticket waits on nothing (its twin answers it with its empty entry too).
    def fetch(ticket)
      return 0 if ticket.id.nil?

      entry = @entries[ticket.id] ||= Waiting.counts_for([ticket.id]).fetch(ticket.id)
      entry[:waiting_on]
    end

    private

    # For Tickets::LazyPagePreload.
    def answered?(ticket_id)
      @entries.key?(ticket_id)
    end
  end
end
