# frozen_string_literal: true

module NotificationsHelper
  # Generate the target URL for a notification based on its notifiable object
  def notification_target_path(notification)
    return '#' unless notification.notifiable

    notifiable = notification.notifiable
    notification.organisation

    case notifiable
    when Ticket
      if notifiable.project
        organisation_project_ticket_path(
          notification.organisation_id,
          notifiable.project,
          notifiable
        )
      else
        organisation_ticket_path(notification.organisation_id, notifiable)
      end
    when Project
      organisation_project_path(notification.organisation_id, notifiable)
    when TimeSession
      if notifiable.ticket
        organisation_project_ticket_path(notification.organisation_id, notifiable.ticket.project, notifiable.ticket, anchor: "time_session_#{notifiable.id}")
      else
        organisation_time_sessions_path(notification.organisation_id, anchor: "time_session_#{notifiable.id}")
      end
    when Note
      if notifiable.project
        organisation_project_note_path(notification.organisation_id, notifiable.project, notifiable)
      else
        organisation_note_path(notification.organisation_id, notifiable)
      end
    when User
      organisation_user_path(notification.organisation_id, notifiable)
    when Comment
      # For comments, go to the parent object with anchor
      parent = notifiable.commentable
      if parent
        "#{notification_target_path_for_object(parent, notification.organisation_id)}#comment_#{notifiable.id}"
      else
        '#'
      end
    else
      # Fallback: try to construct a path based on naming conventions
      begin
        if notifiable.respond_to?(:project) && notifiable.project
          send("organisation_project_#{notifiable.class.name.underscore}_path", notification.organisation_id, notifiable.project, notifiable)
        else
          send("organisation_#{notifiable.class.name.underscore}_path", notification.organisation_id, notifiable)
        end
      rescue NoMethodError
        # Last resort: organisation show page
        organisation_root_path(organisation_id: notification.organisation_id)
      end
    end
  rescue StandardError => e
    Rails.logger.warn "Failed to generate notification target path for #{notification.id}: #{e.message}"
    organisation_root_path(organisation_id: notification.organisation_id)
  end

  def notification_deeplink_path(notification, source: nil)
    return '#' unless notification&.organisation_id

    options = {}
    options[:source] = source if source.present?

    open_organisation_notification_path(notification.organisation_id, notification, options)
  rescue StandardError => e
    Rails.logger.warn "Failed to generate notification deeplink path for #{notification&.id}: #{e.message}"
    notification_target_path(notification)
  end

  def notification_deeplink_url(notification, source: nil)
    return '#' unless notification&.organisation_id

    options = {}
    options[:source] = source if source.present?

    open_organisation_notification_url(notification.organisation_id, notification, options)
  rescue StandardError => e
    Rails.logger.warn "Failed to generate notification deeplink url for #{notification&.id}: #{e.message}"
    begin
      notification_target_path(notification)
    rescue StandardError
      '#'
    end
  end

  private

  def notification_target_path_for_object(object, organisation_id)
    case object
    when Ticket
      if object.project
        organisation_project_ticket_path(organisation_id, object.project, object)
      else
        organisation_ticket_path(organisation_id, object)
      end
    when Project
      organisation_project_path(organisation_id, object)
    when Note
      if object.project
        organisation_project_note_path(organisation_id, object.project, object)
      else
        organisation_note_path(organisation_id, object)
      end
    else
      begin
        if object.respond_to?(:project) && object.project
          send("organisation_project_#{object.class.name.underscore}_path", organisation_id, object.project, object)
        else
          send("organisation_#{object.class.name.underscore}_path", organisation_id, object)
        end
      rescue NoMethodError
        organisation_root_path(organisation_id: organisation_id)
      end
    end
  end
end
