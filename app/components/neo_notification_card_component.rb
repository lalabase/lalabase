# frozen_string_literal: true

class NeoNotificationCardComponent < ViewComponent::Base
  # Include the module with the constants
  include Notifications::Constants

  def initialize(notification:, show_project: true, view_variant: 'card')
    @notification = notification
    @show_project = show_project
    @view_variant = view_variant
  end

  def render?
    @notification.present?
  end

  private

  def state_classes
    NOTIFICATION_STATE_CLASSES.fetch(@notification.state, DEFAULT_STATE_CLASS)
  end

  def border_color_class
    @notification.state_read? ? 'border-gray-300' : 'border-stroke'
  end

  def primary_text_class
    @notification.state_read? ? 'text-gray-500' : 'text-gray-900'
  end

  def secondary_text_class
    @notification.state_read? ? 'text-gray-400' : 'text-gray-600'
  end

  def tertiary_text_class
    @notification.state_read? ? 'text-gray-400' : 'text-gray-500'
  end

  def priority_indicator
    return unless HIGH_PRIORITY_VALUES.include?(@notification.priority)

    css_class = PRIORITY_INDICATOR_CLASSES[@notification.priority]
    return unless css_class

    content_tag(:div, '', class: css_class)
  end

  def event_icon
    # Use the same icons as other components for consistency
    EVENT_TYPE_ICONS.fetch(@notification.event_type, DEFAULT_ICON)
  end

  def time_ago
    created = @notification.created_at || Time.current
    seconds = (Time.current - created).to_i
    minutes = seconds / 60
    hours = minutes / 60
    days = hours / 24
    if days >= 1
      plural = days == 1 ? 'day' : 'days'
      "#{days} #{plural} ago"
    elsif hours >= 1
      plural = hours == 1 ? 'hour' : 'hours'
      "#{hours} #{plural} ago"
    elsif minutes >= 1
      plural = minutes == 1 ? 'minute' : 'minutes'
      "#{minutes} #{plural} ago"
    else
      'just now'
    end
  end

  def notification_url
    url = helpers.notification_deeplink_path(@notification, source: 'notification_center')
    return url unless url == '#'

    fallback_notifiable_url || @notification.try(:action_url) || '#'
  end

  def fallback_notifiable_url
    notifiable = @notification.notifiable
    return nil unless notifiable

    case notifiable
    when Ticket
      helpers.organisation_project_ticket_path(
        helpers.current_organisation,
        notifiable.project,
        notifiable
      )
    when ProjectRepository
      helpers.organisation_project_project_repositories_path(
        helpers.current_organisation,
        notifiable.project
      )
    end
  rescue StandardError
    nil
  end

  def notification_title
    I18n.t("notifications.titles.#{@notification.event_type}", default: @notification.event_type.humanize)
  rescue Exception
    @notification.event_type.to_s.humanize
  end

  def event_type_label
    # Simplified event type labels for mobile view
    case @notification.event_type
    when 'ticket_commented'
      I18n.t('components.neo_notification_card.event_labels.ticket_commented')
    when 'ticket_assigned'
      I18n.t('components.neo_notification_card.event_labels.ticket_assigned')
    when 'ticket_unassigned'
      I18n.t('components.neo_notification_card.event_labels.ticket_unassigned')
    when 'ticket_status_changed'
      I18n.t('components.neo_notification_card.event_labels.ticket_status_changed')
    when 'ticket_created'
      I18n.t('components.neo_notification_card.event_labels.ticket_created')
    when 'ticket_updated'
      I18n.t('components.neo_notification_card.event_labels.ticket_updated')
    when 'ticket_closed'
      I18n.t('components.neo_notification_card.event_labels.ticket_closed')
    when 'mention'
      I18n.t('components.neo_notification_card.event_labels.mention')
    when 'document_added'
      I18n.t('components.neo_notification_card.event_labels.document_added')
    when 'project_announcement'
      I18n.t('components.neo_notification_card.event_labels.project_announcement')
    else
      @notification.event_type.to_s.humanize
    end
  end

  def notification_message
    # Prepare payload with necessary transformations
    payload = @notification.payload.symbolize_keys

    # Map post_excerpt to excerpt for ticket_commented notifications
    payload[:excerpt] = payload[:post_excerpt] if @notification.event_type == 'ticket_commented' && payload[:post_excerpt]

    if @notification.grouped?
      I18n.t("notifications.messages.#{@notification.event_type}_grouped",
             count: @notification.group_count,
             actor: actor_display_name,
             notifiable: notifiable_display_name,
             **payload)
    else
      I18n.t("notifications.messages.#{@notification.event_type}",
             actor: actor_display_name,
             notifiable: notifiable_display_name,
             **payload)
    end
  rescue I18n::MissingInterpolationArgument => e
    # Fallback for corrupted notifications with mismatched event_type and payload
    Rails.logger.warn "Notification #{@notification.id} has mismatched event_type '#{@notification.event_type}' and payload: #{e.message}"

    # Try to infer the correct event type from payload
    inferred_type = infer_event_type_from_payload

    if inferred_type && inferred_type != @notification.event_type
      Rails.logger.warn "Attempting to use inferred event_type '#{inferred_type}' instead of '#{@notification.event_type}'"

      begin
        # Prepare payload with necessary transformations
        fallback_payload = @notification.payload.symbolize_keys
        fallback_payload[:excerpt] = fallback_payload[:post_excerpt] if inferred_type == 'ticket_commented' && fallback_payload[:post_excerpt]

        if @notification.grouped?
          I18n.t("notifications.messages.#{inferred_type}_grouped",
                 count: @notification.group_count,
                 actor: actor_display_name,
                 notifiable: notifiable_display_name,
                 **fallback_payload)
        else
          I18n.t("notifications.messages.#{inferred_type}",
                 actor: actor_display_name,
                 notifiable: notifiable_display_name,
                 **fallback_payload)
        end
      rescue I18n::MissingInterpolationArgument, I18n::MissingTranslationData
        fallback_message
      end
    else
      fallback_message
    end
  rescue Exception
    fallback_message
  end

  def grouped_count_text
    return unless @notification.group_count > 1

    I18n.t('components.neo_notification_card.more_activities', count: @notification.group_count - 1)
  end

  def ticket_accessible?
    return false unless @notification.notifiable.is_a?(Ticket)

    # Check if current user has access to view this ticket
    begin
      current_user = helpers.current_user
      return false unless current_user

      # Use Pundit policy to check access
      TicketPolicy.new(current_user, @notification.notifiable).show?
    rescue StandardError => e
      # If any error occurs (e.g., ticket deleted, no permissions), return false
      Rails.logger.warn("Ticket access check failed for notification #{@notification.id}: #{e.message}")
      false
    end
  end

  def ticket_exists_and_accessible?
    return false unless @notification.notifiable_type == 'Ticket'

    # Check if ticket still exists
    ticket = @notification.notifiable
    return false unless ticket.present?

    ticket_accessible?
  end

  def mark_read_url
    org = @notification.organisation || (defined?(ActsAsTenant) && ActsAsTenant.current_tenant)
    return '#' unless org

    if helpers.respond_to?(:mark_read_organisation_notification_path)
      org_id = if helpers.respond_to?(:current_organisation) && helpers.current_organisation.present?
                 helpers.current_organisation.id
               else
                 org.id
               end
      return helpers.mark_read_organisation_notification_path(org_id, @notification, view_variant: @view_variant)
    end
    "/org/#{org.id}/notifications/#{@notification.id}/mark_read?view_variant=#{@view_variant}"
  end

  def archive_url
    org = @notification.organisation || (defined?(ActsAsTenant) && ActsAsTenant.current_tenant)
    return '#' unless org

    if helpers.respond_to?(:archive_organisation_notification_path)
      org_id = if helpers.respond_to?(:current_organisation) && helpers.current_organisation.present?
                 helpers.current_organisation.id
               else
                 org.id
               end
      return helpers.archive_organisation_notification_path(org_id, @notification)
    end
    "/org/#{org.id}/notifications/#{@notification.id}/archive"
  end

  def infer_event_type_from_payload
    # Try to infer event type from payload data
    return @notification.payload['action'] if @notification.payload['action'].present? && valid_event_type?(@notification.payload['action'])
    return @notification.payload['event_type'] if @notification.payload['event_type'].present? && valid_event_type?(@notification.payload['event_type'])

    # Look for patterns in payload keys using central mapping
    PAYLOAD_PATTERN_MAPPINGS.each do |pattern_keys, event_type|
      return event_type if pattern_keys.any? { |key| @notification.payload[key].present? }
    end

    nil
  end

  def valid_event_type?(type)
    VALID_EVENT_TYPES.include?(type.to_s)
  end

  # The rescue path behind notification_message. Deliberately NOT viewer-aware:
  # it must stay renderable without a view context (helpers raises before the
  # render pipeline), and an error fallback in the default name mode is fine.
  def fallback_message
    I18n.t('components.neo_notification_card.fallback_message',
           actor: @notification.actor&.display_name || 'System',
           notifiable: notifiable_display_name)
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
      @notification.notifiable.respond_to?(:title) ? @notification.notifiable.title : I18n.t('components.neo_notification_card.document_fallback')
    else
      @notification.notifiable.try(:title) || @notification.notifiable.try(:name) || @notification.notifiable.class.name
    end
  end
end
