# frozen_string_literal: true

# Derives the display building blocks of an activity line from a notification:
# event icon, event label, actor name, relative time.
#
# The single source of this derivation — shared between the inbox master line
# (NeoInboxMasterItemComponent) and the "What was new" block in the pane
# (_pane_new_activity). No clone of the logic in two places.
module Inbox
  class ActivityLine
    include Notifications::Constants
    include ActionView::Helpers::DateHelper

    def initialize(notification)
      @notification = notification
    end

    def icon
      EVENT_TYPE_ICONS.fetch(@notification.event_type, DEFAULT_ICON)
    end

    def label
      I18n.t("views.organisations.notifications.event_short.#{@notification.event_type}",
             default: @notification.event_type.to_s.humanize)
    end

    def actor_name
      actor = @notification.actor
      return I18n.t('views.organisations.notifications.item.system_actor', default: 'System') unless actor

      actor.try(:full_name).presence ||
        [actor.try(:first_name), actor.try(:last_name)].compact.join(' ').presence ||
        actor.try(:email) ||
        'Unbekannt'
    end

    def time_ago
      return '' unless @notification.created_at

      # Shared, localized relative-time key (de: "vor X", en: "X ago").
      I18n.t('views.common.relative_time_ago',
             time: time_ago_in_words(@notification.created_at))
    end
  end
end
