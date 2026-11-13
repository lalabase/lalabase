# frozen_string_literal: true

# The Turbo stream names a user's notification UI listens on, in ONE place.
# Entry point: Notifications::Streams.badge / .notifications / .all_inboxes (a naming helper, no side effects)
#
# Every name of an organisation's page carries the organisation: such a page
# shows one organisation, so a
# broadcast computed for organisation B must never reach a page open in
# organisation A. The names were once user-only ("user:<id>:badge"), and the
# inbox count of one organisation showed the unread count of another after
# every notification that arrived there (29.09.2026).
#
# Subscribers (layout, inbox, dropdown) and broadcasters (BroadcastService,
# UnreadSignals) both build the name here, so the two sides cannot drift.
module Notifications
  module Streams
    module_function

    # Nav count, count-data frame, project badges, org switcher signal.
    def badge(user, organisation)
      "user:#{id_of(user)}:org:#{id_of(organisation)}:badge"
    end

    # Inbox list: card replacements and the "new notifications" banner.
    def notifications(user, organisation)
      "user:#{id_of(user)}:org:#{id_of(organisation)}:notifications"
    end

    # The inbox above the organisations (AllInboxesController), per person and
    # WITHOUT an organisation: that page shows all of them. Only that page
    # subscribes, and only Notifications::UnreadSignals sends on it: a signal
    # that carries an opaque stamp (Notifications::InboxQuery.stamp) and nothing
    # else. The page fetches what changed through its own reader. Never a
    # count, a title or an organisation on this name.
    def all_inboxes(user)
      "user:#{id_of(user)}:all_inboxes"
    end

    def id_of(record_or_id)
      record_or_id.respond_to?(:id) ? record_or_id.id : record_or_id
    end
    private_class_method :id_of
  end
end
