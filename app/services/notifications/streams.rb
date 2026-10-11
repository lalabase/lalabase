# frozen_string_literal: true

# The Turbo stream names a user's notification UI listens on, in ONE place.
# Entry point: Notifications::Streams.badge / .notifications (a naming helper, no side effects)
#
# Every name carries the organisation: a page shows one organisation, so a
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

    def id_of(record_or_id)
      record_or_id.respond_to?(:id) ? record_or_id.id : record_or_id
    end
    private_class_method :id_of
  end
end
