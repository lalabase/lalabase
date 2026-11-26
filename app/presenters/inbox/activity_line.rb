# frozen_string_literal: true

# Derives the display building blocks of an activity line from a notification:
# event icon, event label, actor name, relative time.
#
# The single source of this derivation — shared between the inbox master line
# (NeoInboxMasterItemComponent), the "What was new" block in the pane
# (_pane_new_activity) and the event card (_pane_event_card). No clone of the
# logic in two places.
#
# A notification about a PROJECT reports one of its events (a new note, a new
# member), and what the event is about stands in the payload the fanout wrote
# (payload['action'], payload['parameters']). Everything here reads the
# notification alone: the list has no tenant above the organisations, and a
# row must not load its activity.
module Inbox
  class ActivityLine
    include Notifications::Constants
    include ActionView::Helpers::DateHelper

    # The parameters that carry the TITLE of the event's object (ProjectTrackable).
    # A row that stands for one such event shows it instead of the project's name.
    OBJECT_TITLE_KEYS = %w[note_title document_title meeting_title].freeze
    # Every parameter that names what an event on a project is about, titles first.
    OBJECT_NAME_KEYS = (OBJECT_TITLE_KEYS + %w[ticket_title user_name chat_title folder_name view_name]).freeze

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

    # The event in words. A project's event is worded by its action where the
    # event card has a text for it: the event type of such a row is a coarse
    # bucket ("document added" for a note, "announcement" for a new member).
    def event_words
      action = project_parameters && @notification.payload['action'].to_s
      return label unless Inbox::LaneKind::WORDED_CARDS.include?(action)

      I18n.t("views.organisations.notifications.pane.event_card.#{action}.what")
    end

    # Who did what: a notification without an actor (a system message) names
    # the event alone.
    def who_did_what
      @notification.actor ? "#{actor_name} #{event_words}" : event_words
    end

    # The title of the object a project's event is about, or nil.
    def object_title
      project_parameters&.values_at(*OBJECT_TITLE_KEYS)&.find(&:present?)
    end

    # The name of what a project's event is about (a title, a member, a ticket), or nil.
    def object_name
      project_parameters&.values_at(*OBJECT_NAME_KEYS)&.find(&:present?)
    end

    def actor_name
      actor = @notification.actor
      return I18n.t('views.organisations.notifications.item.system_actor', default: 'System') unless actor

      # The one name rule (User#display_name): a member without a name is named
      # by the email they show to others, never by a hidden login address.
      actor.display_name
    end

    # How long ago the row's latest event happened (Notification#happened_at): a
    # row created days ago with an event a moment ago says so, and a row the
    # fanout wrote late names its event's time, though it stands on top.
    def time_ago
      return '' unless @notification.happened_at

      # Shared, localized relative-time key (de: "vor X", en: "X ago").
      I18n.t('views.common.relative_time_ago',
             time: time_ago_in_words(@notification.happened_at))
    end

    private

    # The parameters of the event, for a notification about a project only.
    def project_parameters
      return unless @notification.notifiable_type == Notification::PROJECT_EVENT_TYPE

      parameters = @notification.payload['parameters']
      parameters if parameters.is_a?(Hash)
    end
  end
end
