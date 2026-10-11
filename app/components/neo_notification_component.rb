# frozen_string_literal: true

# Notification item component for individual notifications
#
# PURPOSE:
# Represents a single notification with avatar, content, actions and timing.
# Supports grouped notifications and various event types.
#
# WHY BUILT THIS WAY:
# - Reusable: can be used in dropdown, lists and details
# - Flexible: supports various notification types and states
# - Accessible: screen reader support, keyboard navigation
# - Interactive: integrates mark-as-read and click-to-navigate
# - Performant: ViewComponent eliminates view-logic duplication
# - Consistent: follows the Neo Brutalist design system
#
# EXAMPLE:
# <%= render NeoNotificationComponent.new(notification: @notification) %>
# <%= render NeoNotificationComponent.new(notification: @notification, variant: :compact) %>

class NeoNotificationComponent < ViewComponent::Base
  # Include the module with the constants
  include Notifications::Constants

  attr_reader :notification, :variant, :show_avatar, :show_actions, :clickable

  def initialize(notification:, variant: :default, show_avatar: true, show_actions: true, clickable: true)
    @notification = notification
    @variant = variant.to_sym
    @show_avatar = show_avatar
    @show_actions = show_actions
    @clickable = clickable
  end

  def render?
    @notification.present?
  end

  private

  def notification_classes
    classes = ['notification-item']
    classes << 'notification-item--unread' unless @notification.state_read?
    classes << 'notification-item--grouped' if @notification.grouped?
    classes << "notification-item--#{@variant}" unless @variant == :default
    if @clickable
      begin
        classes << 'notification-item--clickable' if action_url.present?
      rescue Exception
        # Before render, helpers may not be available. Treat as non-clickable.
      end
    end
    classes.join(' ')
  end

  def event_type_icon
    # Use constants for consistency
    EVENT_TYPE_ICONS.fetch(@notification.event_type, DEFAULT_ICON)
  end

  def event_type_color
    EVENT_TYPE_COLORS.fetch(@notification.event_type, DEFAULT_EVENT_COLOR)
  end

  def notification_message
    if @notification.grouped?
      I18n.t("notifications.messages.#{@notification.event_type}_grouped",
             count: @notification.group_count,
             actor: actor_display_name,
             notifiable: notifiable_display_name,
             **@notification.payload.symbolize_keys)
    else
      I18n.t("notifications.messages.#{@notification.event_type}",
             actor: actor_display_name,
             notifiable: notifiable_display_name,
             **@notification.payload.symbolize_keys)
    end
  rescue I18n::MissingInterpolationArgument => e
    Rails.logger.warn "Notification #{@notification.id} has mismatched event_type '#{@notification.event_type}' and payload: #{e.message}"
    fallback_message
  rescue StandardError => e
    Rails.logger.warn "Error generating notification message for #{@notification.id}: #{e.message}"
    fallback_message
  end

  def time_ago_text
    helpers.time_ago_in_words(@notification.created_at)
  rescue Exception
    # Fallback if helper doesn't exist
    distance_in_days = ((Time.current - @notification.created_at) / 1.day).round
    distance_in_days.zero? ? 'today' : "#{distance_in_days}d ago"
  end

  def group_count_text
    return unless @notification.grouped?

    helpers.pluralize(@notification.group_count, 'update')
  rescue Exception
    "#{@notification.group_count} updates"
  end

  def action_url
    deeplink = helpers.notification_deeplink_path(@notification, source: 'notification_center')
    return deeplink if deeplink.present? && deeplink != '#'

    if @notification.respond_to?(:action_url)
      url = @notification.action_url
      return url if url.present?
    end

    # Fallback if action_url method doesn't exist or returned blank
    case @notification.notifiable_type
    when 'Ticket'
      helpers.organisation_project_ticket_path(
        @notification.organisation,
        @notification.notifiable.project,
        @notification.notifiable
      )
    when 'Project'
      helpers.organisation_project_path(
        @notification.organisation,
        @notification.notifiable
      )
    end
  rescue Exception
    nil
  end

  def mark_read_url
    organisation_id = @notification.organisation_id
    if helpers.respond_to?(:mark_read_organisation_notification_path)
      helpers.mark_read_organisation_notification_path(organisation_id, @notification)
    elsif helpers.respond_to?(:organisation_notification_path)
      helpers.organisation_notification_path(organisation_id, @notification)
    else
      "/org/#{organisation_id}/notifications/#{@notification.id}"
    end
  rescue StandardError
    '#'
  end

  def notifiable_title
    case @notification.notifiable
    when nil
      'System'
    else
      @notification.notifiable.try(:title) ||
        @notification.notifiable.try(:name) ||
        @notification.notifiable.class.name
    end
  end

  def priority_class
    return '' unless @notification.respond_to?(:priority)

    HIGH_PRIORITY_VALUES.include?(@notification.priority) ? 'notification-item--high-priority' : ''
  end

  def fallback_message
    "#{@notification.event_type.humanize} notification"
  end

  def actor_display_name
    @notification.actor ? helpers.viewer_display_name(@notification.actor) : 'System'
  end

  def notifiable_display_name
    case @notification.notifiable
    when Ticket
      "##{@notification.notifiable.number} #{@notification.notifiable.title}"
    when Project
      @notification.notifiable.name
    when Document
      @notification.notifiable.title
    else
      @notification.notifiable.try(:title) || @notification.notifiable.try(:name) || @notification.notifiable.class.name
    end
  end
end
