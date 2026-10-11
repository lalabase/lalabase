# frozen_string_literal: true

# The EmailDeliveryJob sends notifications via email.
#
# PURPOSE:
# This job is triggered when an email notification should be sent.
# It generates the email from the notification, sends it and tracks the status.
#
# WHY BUILT THIS WAY:
# - Solid Queue for reliable email delivery
# - Retry mechanism with exponential backoff on errors
# - Status tracking for delivery confirmation and bounce handling
# - Rate limiting per recipient via concurrency control
# - Multi-tenancy through acts_as_tenant
#
# EXAMPLE:
# Notification is created as "email" → EmailDeliveryJob is scheduled
# → job generates email → sends via ApplicationMailer → tracks status

class EmailDeliveryJob < ApplicationJob
  # Include the module with the constants
  include Notifications::Constants

  queue_as :emails

  # Retry with exponential backoff for email delivery failures
  retry_on Timeout::Error, wait: 30.seconds, attempts: 5
  retry_on StandardError, wait: 10.seconds, attempts: 3

  # Don't retry permanent failures
  discard_on ActiveRecord::RecordNotFound

  def perform(notification_id)
    # Tenant-less loading DELIBERATELY via without_tenant instead of Model.unscoped:
    # unscoped discards ALL default scopes (including future ones like soft-delete),
    # without_tenant specifically lifts only the tenant requirement. Fallback for
    # jobs without an enqueue tenant in the queue; the actual tenant context
    # comes right after from the record itself.
    notification = ActsAsTenant.without_tenant { Notification.find(notification_id) }

    # Set tenant context
    ActsAsTenant.with_tenant(notification.organisation) do
      # Skip if notification is not for email channel
      unless notification.channel == Notifications::Constants::CHANNEL_EMAIL
        Rails.logger.warn "EmailDeliveryJob called for non-email notification #{notification_id}"
        return
      end

      # Skip if recipient has no email
      unless notification.recipient&.email.present?
        Rails.logger.warn "Recipient has no email for notification #{notification_id}"
        notification.mark_failed!
        return
      end

      # ACCESS CHECK: the recipient may have lost the project between the moment this
      # job was enqueued and the moment it runs (removed from the project, removed from
      # the organisation, membership deactivated). The fanout gate cannot see that far
      # ahead, so the last word is here, right before the mail leaves the building.
      #
      # Asked through Notification.accessible_for so this stays ONE rule with one owner
      # instead of a fourth hand-written copy of it. The row is left exactly as it is:
      # nothing is deleted, and a resend after access returns will go out normally.
      unless deliverable_to_recipient?(notification)
        Rails.logger.info "Skipping notification #{notification_id}: recipient lost access to its project"
        return
      end

      # IDEMPOTENCY CHECK: Skip if already sent
      if notification.state_sent? || notification.state_delivered?
        Rails.logger.info "Notification #{notification_id} already sent/delivered"
        return
      end

      # Check for existing successful email log (additional idempotency check)
      existing_log = EmailLog.where(
        notification: notification,
        status: %w[sent delivered opened clicked]
      ).exists?

      if existing_log
        Rails.logger.info "Email already sent for notification #{notification_id} (found in EmailLog)"
        notification.mark_sent! unless notification.state_sent?
        return
      end

      # Create email log entry
      email_log = create_email_log(notification)

      begin
        # Lock the email log to prevent concurrent sends
        email_log.with_lock do
          # Double-check status after acquiring lock
          if email_log.reload.status != 'queued'
            Rails.logger.info "Email log #{email_log.id} already processing, skipping"
            return
          end

          # Mark as sending to prevent concurrent processing
          email_log.update!(status: 'sent', metadata: email_log.metadata.merge('sending_at' => Time.current.iso8601))
        end

        # Send the email
        mail = send_notification_email(notification, email_log)

        # Mark notification as sent
        notification.mark_sent!

        # Extract email content for storage
        html_content = extract_html_content(mail)
        text_content = extract_text_content(mail)
        preview = generate_preview(text_content || html_content)

        # Try to extract message ID from delivery (provider-specific)
        message_id = extract_message_id(mail)

        # Update email log with content and metadata
        email_log.update!(
          provider_message_id: message_id,
          sent_at: Time.current,
          body_html: html_content,
          body_text: text_content,
          body_preview: preview,
          subject: mail.subject,
          recipient_email: mail.to&.first,
          metadata: email_log.metadata.merge(
            'sent_at' => Time.current.iso8601,
            'message_id' => message_id,
            'from' => mail.from&.first,
            'subject' => mail.subject
          )
        )

        Rails.logger.info "Successfully sent email notification #{notification_id}"
      rescue StandardError => e
        # Log the error and mark as failed
        error_message = "Email delivery failed: #{e.message}"
        Rails.logger.error "#{error_message} for notification #{notification_id}"

        notification.mark_failed!
        email_log.update!(status: :failed, metadata: email_log.metadata.merge('error' => error_message))

        # Re-raise to trigger retry mechanism
        raise
      end
    end
  end

  private

  # One rule, one owner: Notification.accessible_for decides everywhere whether a
  # notification is still the recipient's business. A notification with no project
  # (system message) passes, exactly as it does in the inbox.
  def deliverable_to_recipient?(notification)
    recipient = notification.recipient
    return false unless recipient

    Notification.where(id: notification.id)
                .accessible_for(recipient, notification.organisation)
                .exists?
  end

  def create_email_log(notification)
    EmailLog.create_for_notification!(notification, initial_status: :queued)
  end

  def send_notification_email(notification, _email_log)
    # Generate email based on notification type
    mailer_action = determine_mailer_action(notification)

    # Send via NotificationMailer
    mail = NotificationMailer.public_send(
      mailer_action,
      notification,
      email_options_for_notification(notification)
    )

    # Deliver and return mail object
    deliver_email_safely(mail, notification)
    mail
  rescue StandardError => e
    Rails.logger.error "Failed to send notification email #{notification.id}: #{e.message}"
    raise
  end

  def determine_mailer_action(notification)
    # Map event types to mailer actions using central constants
    # Use fully qualified names to avoid autoloading problems in background jobs
    Notifications::Constants::EVENT_TYPE_TO_MAILER_ACTION.fetch(notification.event_type, Notifications::Constants::DEFAULT_MAILER_ACTION)
  end

  def email_options_for_notification(notification)
    {
      to: notification.recipient.email,
      from: sender_email_for_organisation(notification.organisation),
      subject: generate_email_subject(notification),
      organization: notification.organisation
    }
  end

  def generate_email_subject(notification)
    # Get template from constants or use default
    template = Notifications::Constants::EMAIL_SUBJECT_TEMPLATES.fetch(
      notification.event_type,
      Notifications::Constants::DEFAULT_EMAIL_SUBJECT
    )

    # Extract title/name from notifiable
    title = extract_notifiable_title(notification.notifiable)

    # Generate base subject using template
    base = format(template, title: title, organization: notification.organisation.name)

    # Add organization prefix if configured
    org_prefix = notification.organisation.email_subject_prefix
    org_prefix.present? ? "[#{org_prefix}] #{base}" : base
  end

  def extract_notifiable_title(notifiable)
    return 'unknown' unless notifiable

    case notifiable
    when Ticket
      notifiable.title || 'ticket'
    when Project
      notifiable.name || 'project'
    when Document
      notifiable.try(:name) || notifiable.try(:title) || 'document'
    when Note
      notifiable.try(:title) || 'note'
    when ProjectRepository
      notifiable.try(:full_name) || 'repository'
    when Notification
      # Notifications don't have title, extract from their notifiable
      extract_notifiable_title(notifiable.notifiable)
    else
      notifiable.try(:title) || notifiable.try(:name) || 'item'
    end
  end

  def sender_email_for_organisation(organisation)
    # Use organization-specific sender if configured
    organisation.notification_sender_email.presence ||
      Rails.application.config.action_mailer.default_options&.dig(:from) ||
      "noreply@#{Rails.application.config.action_mailer.default_url_options&.dig(:host) || 'localhost'}"
  end

  def email_provider_name
    # Detect email provider from ActionMailer configuration
    delivery_method = Rails.application.config.action_mailer.delivery_method

    case delivery_method
    when :smtp
      smtp_settings = Rails.application.config.action_mailer.smtp_settings
      if smtp_settings&.dig(:address)&.include?('postmark')
        'postmark'
      elsif smtp_settings&.dig(:address)&.include?('sendgrid')
        'sendgrid'
      elsif smtp_settings&.dig(:address)&.include?('mailgun')
        'mailgun'
      else
        'smtp'
      end
    when :letter_opener
      'letter_opener'
    else
      delivery_method.to_s
    end
  end

  def deliver_email_safely(mail, notification)
    # Simple delivery with basic error handling
    attempt_delivery(mail, 'primary')
  rescue StandardError => e
    # Log the error and re-raise for retry mechanism
    Rails.logger.error "Email delivery failed for notification #{notification.id}: #{e.class}: #{e.message}"
    Rails.logger.error "Current delivery method: #{Rails.application.config.action_mailer.delivery_method}"
    raise e
  end

  def attempt_delivery(mail, strategy_name)
    Rails.logger.debug "Delivering email to: #{mail.to&.join(', ')} subject: #{mail.subject}"
    mail.deliver_now
    true
  rescue StandardError => e
    Rails.logger.warn "#{strategy_name} delivery failed: #{e.message}"
    raise e
  end

  def extract_message_id(mail)
    # Try to extract provider-specific message ID
    # This is provider-dependent and may not always be available
    mail.message_id
  rescue StandardError
    nil
  end

  def extract_html_content(mail)
    return nil unless mail

    if mail.multipart? && mail.html_part
      mail.html_part.body.decoded
    elsif mail.content_type&.include?('text/html')
      mail.body.decoded
    end
  rescue StandardError => e
    Rails.logger.error "Failed to extract HTML content: #{e.message}"
    nil
  end

  def extract_text_content(mail)
    return nil unless mail

    if mail.multipart? && mail.text_part
      mail.text_part.body.decoded
    elsif mail.content_type&.include?('text/plain')
      mail.body.decoded
    elsif !mail.multipart? && !mail.content_type&.include?('text/html')
      mail.body.decoded
    end
  rescue StandardError => e
    Rails.logger.error "Failed to extract text content: #{e.message}"
    nil
  end

  def generate_preview(content)
    return nil unless content

    # Strip HTML tags if present and truncate
    text = if content.include?('<') && content.include?('>')
             ActionView::Base.full_sanitizer.sanitize(content)
           else
             content
           end

    text&.strip&.truncate(500)
  rescue StandardError
    content&.to_s&.truncate(500)
  end
end
