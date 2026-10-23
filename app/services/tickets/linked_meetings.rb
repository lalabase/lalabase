# frozen_string_literal: true

# The meetings that link to a ticket and that a person may read, oldest link
# first, projects preloaded for the paths. Each meeting is judged against its OWN
# project (MeetingPolicy::Scope): a ticket moved to another project keeps its
# meeting links, so the ticket's project answers neither who may see a meeting
# nor where its page is. The one owner of this question; nothing composes the
# join without the scope.
#
# Entry point: call
module Tickets
  class LinkedMeetings
    def self.call(ticket:, user:)
      new(ticket: ticket, user: user).call
    end

    def initialize(ticket:, user:)
      @ticket = ticket
      @user = user
    end

    def call
      links = Reference.pointing_to(@ticket).where(source_type: Meeting.polymorphic_name)
      # Most tickets have no meeting: answer without resolving permissions.
      return Meeting.none unless links.exists?

      MeetingPolicy::Scope.new(@user, Meeting).resolve
                          .joins(:outgoing_references).merge(links)
                          .includes(:project)
                          .order(Reference.arel_table[:created_at])
    end
  end
end
