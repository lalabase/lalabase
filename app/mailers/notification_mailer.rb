# frozen_string_literal: true

# The NotificationMailer generates emails from notifications.
#
# PURPOSE:
# This mailer turns notification objects into appealing emails.
# It uses the notification data and creates contextually appropriate email templates.
#
# WHY BUILT THIS WAY:
# - Template-based emails for different event types
# - Reusable partials for common elements
# - Multi-tenancy support with organisation-specific customizations
# - Responsive email design for all devices
# - Unsubscribe links and preference management
#
# EXAMPLE:
# Notification "ticket_commented" → ticket_comment(notification, options)
# → Uses a template with ticket context and comment details

class NotificationMailer < ApplicationMailer
  # Set default sender and layout
  default from: -> { default_sender }
  layout 'notification_mailer'

  def ticket_comment(notification, options = {})
    setup_notification_email(notification, options)

    @ticket = @notification.notifiable
    @comment = readable_by_recipient(find_related_comment)
    @previous_comment = find_previous_comment(@comment)
    @action_url = ticket_url(@ticket)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.ticket_comment.subject'))
    )
  end

  def ticket_assignment(notification, options = {})
    setup_notification_email(notification, options)

    @ticket = @notification.notifiable
    # GDPR: Resolve assignee from activity.secondary, not from payload PII
    activity = Activity.find_by(id: @notification.payload['activity_id'])
    @assignee = activity&.secondary&.full_name || 'Unknown'
    @action_url = ticket_url(@ticket)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.ticket_assignment.subject'))
    )
  end

  def project_announcement(notification, options = {})
    setup_notification_email(notification, options)

    @project = @notification.notifiable
    @announcement = @notification.payload['announcement_content']
    @action_url = project_url(@project)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.project_announcement.subject'))
    )
  end

  def ticket_status_changed(notification, options = {})
    setup_notification_email(notification, options)

    @ticket = @notification.notifiable
    @old_status = @notification.payload['old_status']
    @new_status = @notification.payload['new_status']
    @action_url = @notification.action_url || ticket_url(@ticket)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.ticket_status_changed.subject'))
    )
  end

  def ticket_blocker(notification, options = {})
    setup_notification_email(notification, options)

    @ticket = @notification.notifiable
    @action_url = @notification.action_url || ticket_url(@ticket)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.ticket_blocker.subject'))
    )
  end

  def ticket_priority_changed(notification, options = {})
    setup_notification_email(notification, options)

    @ticket = @notification.notifiable
    @old_priority = @notification.payload['old_priority']
    @new_priority = @notification.payload['new_priority']
    @action_url = @notification.action_url || ticket_url(@ticket)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.ticket_priority_changed.subject'))
    )
  end

  def document_added(notification, options = {})
    setup_notification_email(notification, options)

    @document = @notification.notifiable
    @action_url = @notification.action_url || document_url(@document)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.document_added.subject'))
    )
  end

  def mention(notification, options = {})
    setup_notification_email(notification, options)

    @mentioned_in = @notification.notifiable
    @mention_context = @notification.payload['mention_context']
    @action_url = @notification.action_url || mention_url(@mentioned_in)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.mention.subject'))
    )
  end

  # One mail for a bulk change of several tickets (doc/ticket_bulk_edit_plan.md,
  # D4): the run's numbers come with the activity's parameters in the payload.
  # One mail for the three bulk runs (change, move, delete): the texts come
  # from the event type's own scope (slice 7).
  def tickets_bulk_changed(notification, options = {})
    setup_notification_email(notification, options)

    @action_url = notification_url(@notification)
    @run_parameters = @notification.payload['parameters'] || {}
    @bulk_scope = "notification_mailer.#{@notification.event_type}"

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t("#{@bulk_scope}.subject", count: @run_parameters['count'].to_i))
    )
  end

  def system_message(notification, options = {})
    setup_notification_email(notification, options)

    @action_url = @notification.action_url

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.system_message.subject'))
    )
  end

  def index_completed(notification, options = {})
    setup_notification_email(notification, options)

    @repository = @notification.notifiable
    @action_url = repository_url(@repository)

    mail(
      to: @recipient_email,
      subject: options[:subject] ||
               default_subject(I18n.t('notification_mailer.index_completed.subject', repo: repository_full_name))
    )
  end

  def index_failed(notification, options = {})
    setup_notification_email(notification, options)

    @repository = @notification.notifiable
    # The error text lives on the index (already token-scrubbed by fail_index!),
    # NOT in the notification payload — the payload stays PII/secret-free.
    @error_message = @repository.try(:project_index)&.error_message
    @action_url = repository_url(@repository)

    mail(
      to: @recipient_email,
      subject: options[:subject] ||
               default_subject(I18n.t('notification_mailer.index_failed.subject', repo: repository_full_name))
    )
  end

  def generic_notification(notification, options = {})
    setup_notification_email(notification, options)

    @action_url = notification_url(@notification)

    mail(
      to: @recipient_email,
      subject: options[:subject] || default_subject(I18n.t('notification_mailer.generic_notification.subject'))
    )
  end

  private

  def setup_notification_email(notification, options)
    @notification = notification
    @recipient = notification.recipient
    @recipient_email = options[:to] || @recipient.email
    @organisation = options[:organization] || notification.organisation
    @actor = notification.actor
    @unsubscribe_url = generate_unsubscribe_url(@recipient, notification.event_type)
    @preferences_url = generate_preferences_url(@recipient)

    # Set tenant context for URL generation
    ActsAsTenant.current_tenant = @organisation
  end

  def default_sender
    if @organisation&.notification_sender_email.present?
      "#{@organisation.name} <#{@organisation.notification_sender_email}>"
    else
      # Use SMTP username as sender to ensure authentication matches
      smtp_username = ENV['SMTP_USERNAME'] || Rails.application.config.action_mailer.smtp_settings&.dig(:user_name)
      smtp_username || Rails.application.config.action_mailer.default_options&.dig(:from) ||
        "noreply@#{Rails.application.config.action_mailer.default_url_options&.dig(:host) || 'localhost'}"
    end
  end

  def default_subject(base_subject)
    prefix = @organisation&.email_subject_prefix
    prefix.present? ? "[#{prefix}] #{base_subject}" : base_subject
  end

  def find_related_comment
    # Try to find the related comment/post from the activity
    activity_id = @notification.payload['activity_id']
    return nil unless activity_id

    activity = Activity.find_by(id: activity_id)
    return nil unless activity

    # If the activity has a secondary object (like a post), return that
    activity.secondary
  rescue StandardError
    nil
  end

  # The fanout picked readers of the comment, but this mail renders later, in a job:
  # a comment may have turned private in between (Post.readable_by)
  def readable_by_recipient(comment)
    comment if !comment.is_a?(Post) || comment.readable_by?(@recipient)
  end

  def find_previous_comment(current_comment)
    return nil unless current_comment.is_a?(Post)
    return nil unless current_comment.ticket

    # Find the previous post (comment) on the same ticket, chronologically before the
    # current one, among those the recipient may read
    current_comment.ticket.posts.readable_by(@recipient, current_comment.organisation)
                   .where('created_at < ?', current_comment.created_at)
                   .order(created_at: :desc)
                   .first
  rescue StandardError => e
    Rails.logger.warn "Failed to find previous comment: #{e.message}"
    nil
  end

  def ticket_url(ticket)
    return '#' unless ticket

    if defined?(@notification) && @notification.present?
      deeplink = notification_deeplink_url_for(@notification, source: 'email')
      return deeplink if deeplink.present?
    end

    Rails.application.routes.url_helpers.organisation_project_ticket_url(
      organisation_identifier,
      ticket.project,
      ticket,
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    )
  rescue StandardError => e
    Rails.logger.error "Failed to generate ticket URL: #{e.message}"
    fallback_url
  end

  def project_url(project)
    return '#' unless project

    if defined?(@notification) && @notification.present?
      deeplink = notification_deeplink_url_for(@notification, source: 'email')
      return deeplink if deeplink.present?
    end

    Rails.application.routes.url_helpers.organisation_project_url(
      organisation_identifier,
      project,
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    )
  rescue StandardError => e
    Rails.logger.error "Failed to generate project URL: #{e.message}"
    fallback_url
  end

  # Repo full_name comes from the notification payload (always present, PII-free);
  # fall back to the live record if the payload is ever missing it.
  def repository_full_name
    @notification.payload['full_name'].presence || @repository&.full_name || 'repository'
  end

  def repository_url(repository)
    return fallback_url unless repository

    Rails.application.routes.url_helpers.organisation_project_project_repositories_url(
      organisation_identifier,
      repository.project,
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    )
  rescue StandardError => e
    Rails.logger.error "Failed to generate repository URL: #{e.message}"
    fallback_url
  end

  def document_url(document)
    return '#' unless document

    # Handle different document types
    case document
    when Note
      if defined?(@notification) && @notification.present?
        deeplink = notification_deeplink_url_for(@notification, source: 'email')
        return deeplink if deeplink.present?
      end
      Rails.application.routes.url_helpers.organisation_project_note_url(
        organisation_identifier,
        document.project,
        document,
        host: default_url_options[:host],
        protocol: default_url_options[:protocol]
      )
    when Document
      if defined?(@notification) && @notification.present?
        deeplink = notification_deeplink_url_for(@notification, source: 'email')
        return deeplink if deeplink.present?
      end
      Rails.application.routes.url_helpers.organisation_project_document_url(
        organisation_identifier,
        document.project,
        document,
        host: default_url_options[:host],
        protocol: default_url_options[:protocol]
      )
    else
      fallback_url
    end
  rescue StandardError => e
    Rails.logger.error "Failed to generate document URL: #{e.message}"
    fallback_url
  end

  def mention_url(mentionable)
    # Generate URL based on what was mentioned in
    case mentionable
    when Ticket
      ticket_url(mentionable)
    when Project
      project_url(mentionable)
    else
      notification_url(@notification)
    end
  end

  def notification_url(notification)
    deeplink = notification_deeplink_url_for(notification, source: 'email')
    return deeplink if deeplink.present?

    Rails.application.routes.url_helpers.organisation_notification_url(
      organisation_identifier,
      notification,
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    )
  rescue StandardError => e
    Rails.logger.error "Failed to generate notification URL: #{e.message}"
    Rails.application.routes.url_helpers.organisation_dashboard_url(
      organisation_identifier,
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    )
  end

  def notification_deeplink_url_for(notification, source: nil)
    return nil unless notification

    options = {
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    }
    options[:source] = source if source.present?

    Rails.application.routes.url_helpers.open_organisation_notification_url(
      organisation_identifier,
      notification,
      options
    )
  rescue StandardError => e
    Rails.logger.warn "Failed to generate notification deeplink url for #{notification.id}: #{e.message}"
    nil
  end

  def generate_unsubscribe_url(recipient, event_type)
    Rails.application.routes.url_helpers.unsubscribe_notifications_url(
      token: generate_unsubscribe_token(recipient, event_type)
    )
  rescue StandardError
    '#'
  end

  def generate_preferences_url(_recipient)
    Rails.application.routes.url_helpers.preferences_organisation_notifications_url(
      organisation_identifier,
      host: default_url_options[:host],
      protocol: default_url_options[:protocol]
    )
  rescue StandardError => e
    Rails.logger.error "Failed to generate notification preferences URL: #{e.message}"
    '#'
  end

  def generate_unsubscribe_token(recipient, event_type)
    # Generate a secure token for unsubscribe links
    payload = {
      user_id: recipient.id,
      event_type: event_type,
      organisation_id: @organisation.id,
      exp: 1.year.from_now.to_i
    }

    JWT.encode(payload, Rails.application.secret_key_base, 'HS256')
  rescue StandardError
    'invalid'
  end

  def organisation_identifier
    @organisation&.id
  end

  def fallback_url
    @notification ? notification_url(@notification) : '#'
  rescue StandardError => e
    Rails.logger.error "Failed to generate fallback notification URL: #{e.message}"
    '#'
  end
end
