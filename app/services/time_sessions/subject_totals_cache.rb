# frozen_string_literal: true

# One request's answers about booked time per ticket.
#
# Entry point: fetch
#
# A list registers its page (Tickets::LazyPagePreload) and the first read
# preloads it (one query); any row the preload never saw — the single-row
# turbo-stream re-render after a save — is looked up on its own.
# That fallback is the point: a miss must cost one query, never render an empty
# cell, because an empty cell is a WRONG number rather than a missing one, and
# nothing about it looks broken.
#
# An object rather than a handful of helper instance variables so the caching
# itself can be tested, and so the rule "a miss is looked up, not zeroed" has one
# place to live instead of being re-decided at each call site.
#
# Made for ONE reader: the tier and every answer are that reader's, so a cache
# told the user per read would answer a second reader from the first one's
# scope and entries (review round 6 of #949).
module TimeSessions
  class SubjectTotalsCache
    prepend Tickets::LazyPagePreload

    def initialize(user:)
      @user = user
      @entries = {}
      @scopes = {}
    end

    # Fills the cache for a page in ONE query per project (the ticket list shows
    # one). Each ticket is read in its own project's scope, as its single lookup
    # would read it. Returns self so a view can call it as a statement.
    def preload(tickets)
      tickets.group_by(&:project_id).each_value do |project_tickets|
        scope = scope_for(project_tickets.first.project)
        @entries.merge!(SubjectTotals.call(scope: scope, ticket_ids: project_tickets.map(&:id)))
      end
      self
    end

    def fetch(ticket)
      @entries[ticket.id] ||= SubjectTotals.call(
        scope: scope_for(ticket.project), ticket_ids: [ticket.id]
      ).fetch(ticket.id, SubjectTotals.empty_entry)
    end

    private

    # Memoized per project: the tier costs a permission lookup, and one render
    # asks for it once per page plus once per stray row.
    def scope_for(project)
      @scopes[project.id] ||= ViewingScope.call(user: @user, project: project).apply(project.time_sessions)
    end

    # For Tickets::LazyPagePreload.
    def answered?(ticket_id)
      @entries.key?(ticket_id)
    end
  end
end
