# frozen_string_literal: true

# Presenter for notification data for use in mailer views and other contexts
# where ViewComponents are not available.
#
# PURPOSE:
# Separates view logic from the model and provides consistent presentation.
#
# USAGE:
# presenter = NotificationPresenter.new(notification)
# presenter.title  # => "Ticket assigned"
# presenter.message # => "Tim assigned ticket #123 to you"

class NotificationPresenter
  include Notifications::Constants

  attr_reader :notification

  delegate :recipient, :actor, :notifiable, :event_type, :grouped?,
           :group_count, :payload, :priority, :unread?, :organisation,
           to: :notification

  def initialize(notification)
    @notification = notification
  end

  def title
    I18n.t("notifications.titles.#{event_type}", default: event_type.humanize)
  end

  def message
    if grouped?
      I18n.t("notifications.messages.#{event_type}_grouped",
             count: group_count,
             actor: actor_display_name,
             notifiable: notifiable_display_name,
             **payload.symbolize_keys)
    else
      I18n.t("notifications.messages.#{event_type}",
             actor: actor_display_name,
             notifiable: notifiable_display_name,
             **payload.symbolize_keys)
    end
  rescue I18n::MissingInterpolationArgument => e
    Rails.logger.warn "Notification #{notification.id} has mismatched event_type '#{event_type}' and payload: #{e.message}"
    fallback_message
  rescue StandardError => e
    Rails.logger.warn "Error generating notification message for #{notification.id}: #{e.message}"
    fallback_message
  end

  def icon
    EVENT_TYPE_ICONS.fetch(event_type, DEFAULT_ICON)
  end

  private

  def fallback_message
    "Benachrichtigung: #{actor_display_name} hat eine Aktion zu #{notifiable_display_name} durchgeführt"
  end

  def actor_display_name
    actor&.full_name || 'System'
  end

  def notifiable_display_name
    case notifiable
    when Ticket
      "##{notifiable.number} #{notifiable.title}"
    when Project
      notifiable.name
    when Document
      # Document has no name: its title lives on the current version. With
      # `.name` the presenter raised INSIDE its own fallback (the rescue calls
      # this method again), so a Document notifiable crashed every caller.
      notifiable.title
    else
      notifiable.try(:title) || notifiable.try(:name) || notifiable.class.name
    end
  end
end
