# frozen_string_literal: true

# The page a list registers with a per-request count cache: the first read of any ticket on it
# loads the whole page in one go, and a page nothing reads costs no query (reviews 3 to 6 of
# #949). So what a table, a phone row or a board card shows decides what is counted, and no
# list has to name its counts.
#
# Entry point: register (fetch is the cache's own, wrapped)
#
# Prepended to the count caches of the ticket list (TimeSessions::SubjectTotalsCache,
# Tickets::SubtaskCountsCache, Tickets::WaitingCountsCache), so it wraps their fetch and no
# cache has to call it. What a cache must bring:
# - `fetch(ticket)`, which answers a ticket on its own on a miss, and a ticket without an id
#   too (the module hands it through untouched);
# - `preload(tickets)`, which answers EVERY ticket it is given (a ticket it leaves out is off
#   every page and falls back to its single lookup: slower, not wrong);
# - a private `answered?(ticket_id)`.
# The module keeps its pages in @registered_pages; a cache does not use that name. A cache that
# needs a reader (the time cache) is made for one, never told per read. The module spec finds
# every class that carries the module and wants an example for it.
module Tickets
  module LazyPagePreload
    # Remembers the page, without the tickets already answered. Returns self.
    def register(tickets)
      page = tickets.reject { |ticket| ticket.id.nil? || answered?(ticket.id) }.index_by(&:id)
      (@registered_pages ||= []) << page if page.any?
      self
    end

    def fetch(ticket)
      load_registered_page(ticket)
      super
    end

    private

    # Loads the registered page that holds `ticket`, once, and takes its tickets off every
    # other page: a ticket shared by two pages is answered once and never overwritten. A ticket
    # answered before its page came is not on it (register).
    def load_registered_page(ticket)
      page = @registered_pages&.find { |tickets_by_id| tickets_by_id.key?(ticket.id) }
      return unless page

      @registered_pages.delete(page)
      @registered_pages.each { |other| other.except!(*page.keys) }
      @registered_pages.reject!(&:empty?)
      preload(page.values)
    end
  end
end
