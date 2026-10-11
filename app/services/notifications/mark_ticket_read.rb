# frozen_string_literal: true

# Marks every unread in-app notification one user holds about one ticket as read:
# comments, assignments, status changes and mentions alike (they all name the
# ticket as their notifiable). The user decided on 30.09.2026 that a ticket is
# read once its view has been open for a moment, or once the user comments on
# it; until then only the inbox, the "read" buttons and a reaction cleared the
# marks, and opening or answering a ticket left them standing everywhere.
#
# Two steps, because the callers differ in WHEN they may broadcast:
#   ids = Notifications::MarkTicketRead.call(user:, ticket:)   # the write
#   Notifications::MarkTicketRead.broadcast(ids)               # after commit
# A controller does both at once; an actor writes in #perform and broadcasts
# from enqueue_after_commit, so no job reads the old state.
#
# The write goes through Notification.bulk_transition!, which also refreshes the
# org switcher signal (Notifications::UnreadSignals).
module Notifications
  class MarkTicketRead
    def self.call(**)
      new(**).call
    end

    # Inbox list cards and the count streams of the ticket's organisation, for
    # every page of the user that has them open.
    def self.broadcast(ids)
      Notification.where(id: ids).find_each do |notification|
        Notifications::BroadcastService.new(notification).broadcast_update
      rescue StandardError => e
        Rails.logger.warn("MarkTicketRead broadcast failed for #{notification.id}: #{e.class}: #{e.message}")
      end
    end

    def initialize(user:, ticket:)
      @user = user
      @ticket = ticket
    end

    # Returns the ids it marked, empty when there was nothing unread.
    def call
      ids = @user.notifications.channel_in_app.unread
                 .where(organisation_id: @ticket.organisation_id, notifiable: @ticket)
                 .pluck(:id)
      Notification.where(id: ids).unread.bulk_transition!(state: 'read', read_at: Time.current) if ids.any?
      ids
    end
  end
end
