# frozen_string_literal: true

class NeoNotificationGroupedItemComponent < ViewComponent::Base
  include Notifications::Constants

  def initialize(notification:, view_variant: 'grouped')
    @notification = notification
    @view_variant = view_variant
  end

  private

  def event_icon
    EVENT_TYPE_ICONS.fetch(@notification.event_type, 'bell')
  end

  def time_display
    @notification.created_at.strftime('%H:%M')
  end

  def event_description
    case @notification.event_type
    when 'ticket_commented'
      # Check in parameters sub-hash first, then in payload root
      excerpt = @notification.payload.dig('parameters', 'post_excerpt') ||
                @notification.payload['post_excerpt'] ||
                @notification.payload['excerpt'] ||
                ''
      # Clean up HTML and whitespace
      clean_excerpt = excerpt.gsub(/<[^>]*>/, '').strip.gsub(/\s+/, ' ')
      truncated_excerpt = clean_excerpt.present? ? truncate(clean_excerpt, length: 100) : ''

      if truncated_excerpt.present?
        "#{actor_name}: #{truncated_excerpt}"
      else
        "#{actor_name} kommentierte"
      end
    when 'ticket_assigned'
      # GDPR: Resolve assignee name from activity.secondary, not from payload PII
      assignee_name = resolve_assignee_name
      if assignee_name
        "#{actor_name} wies das Ticket #{assignee_name} zu"
      else
        "#{actor_name} wies das Ticket zu"
      end
    when 'ticket_unassigned'
      "#{actor_name} entfernte die Zuweisung"
    when 'ticket_status_changed'
      # Check in parameters sub-hash first, then in payload root
      status = @notification.payload.dig('parameters', 'to_status') ||
               @notification.payload.dig('parameters', 'new_status') ||
               @notification.payload.dig('parameters', 'status') ||
               @notification.payload['to_status'] ||
               @notification.payload['new_status'] ||
               @notification.payload['status'] ||
               nil
      if status
        "#{actor_name} änderte Status zu \"#{status}\""
      else
        "#{actor_name} änderte den Status"
      end
    when 'time_session_created'
      duration = @notification.payload.dig('parameters', 'duration') ||
                 @notification.payload.dig('parameters', 'time_spent') ||
                 @notification.payload['duration'] ||
                 @notification.payload['time_spent']
      if duration
        # Replace period with comma for German number formatting
        formatted_duration = duration.to_s.gsub('.', ',')
        "#{actor_name} erfasste #{formatted_duration}"
      else
        "#{actor_name} erfasste Zeit"
      end
    when 'document_added'
      doc_name = @notification.payload['document_name'] || @notification.payload['title']
      if doc_name
        "#{actor_name} fügte \"#{truncate(doc_name, length: 30)}\" hinzu"
      else
        "#{actor_name} fügte ein Dokument hinzu"
      end
    else
      "#{actor_name} #{@notification.event_type.humanize.downcase}"
    end
  end

  def actor_name
    @notification.actor ? helpers.viewer_display_name(@notification.actor) : 'System'
  end

  def resolve_assignee_name
    activity_id = @notification.payload['activity_id']
    return nil unless activity_id

    activity = Activity.find_by(id: activity_id)
    activity&.secondary && helpers.viewer_display_name(activity.secondary)
  end

  def truncate(text, length:)
    return '' if text.blank?

    text.length > length ? "#{text[0...length]}..." : text
  end

  def state_indicator
    if @notification.unread?
      content_tag(:span, '', class: 'inline-block w-2 h-2 bg-lime-400 rounded-full mr-2')
    else
      content_tag(:span, '', class: 'inline-block w-2 h-2 mr-2')
    end
  end

  def mark_read_url
    organisation = helpers.current_organisation if helpers.respond_to?(:current_organisation)
    organisation ||= @notification.organisation || (defined?(ActsAsTenant) && ActsAsTenant.current_tenant)
    return '#' unless organisation

    organisation_id = organisation.respond_to?(:id) ? organisation.id : organisation

    if helpers.respond_to?(:mark_read_organisation_notification_path)
      helpers.mark_read_organisation_notification_path(organisation_id, @notification, view_variant: @view_variant)
    else
      "/org/#{organisation_id}/notifications/#{@notification.id}/mark_read?view_variant=#{@view_variant}"
    end
  end

  def archive_url
    organisation = helpers.current_organisation if helpers.respond_to?(:current_organisation)
    organisation ||= @notification.organisation || (defined?(ActsAsTenant) && ActsAsTenant.current_tenant)
    return '#' unless organisation

    organisation_id = organisation.respond_to?(:id) ? organisation.id : organisation

    if helpers.respond_to?(:archive_organisation_notification_path)
      helpers.archive_organisation_notification_path(organisation_id, @notification, view_variant: @view_variant)
    else
      "/org/#{organisation_id}/notifications/#{@notification.id}/archive?view_variant=#{@view_variant}"
    end
  end

  def unarchive_url
    organisation = helpers.current_organisation if helpers.respond_to?(:current_organisation)
    organisation ||= @notification.organisation || (defined?(ActsAsTenant) && ActsAsTenant.current_tenant)
    return '#' unless organisation

    organisation_id = organisation.respond_to?(:id) ? organisation.id : organisation

    if helpers.respond_to?(:mark_unread_organisation_notification_path)
      helpers.mark_unread_organisation_notification_path(organisation_id, @notification, view_variant: @view_variant)
    else
      "/org/#{organisation_id}/notifications/#{@notification.id}/mark_unread?view_variant=#{@view_variant}"
    end
  end

  def primary_text_class
    @notification.state_read? ? 'text-gray-500' : 'text-gray-700'
  end

  def secondary_text_class
    @notification.state_read? ? 'text-gray-400' : 'text-gray-500'
  end
end
