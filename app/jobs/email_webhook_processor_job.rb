# frozen_string_literal: true

# Processes email provider webhooks (bounce, open, click, etc.) asynchronously.
# Webhook endpoints respond immediately, processing runs in the background.

class EmailWebhookProcessorJob < ApplicationJob
  queue_as :webhooks

  retry_on StandardError, wait: 10.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(provider, event_type, payload, message_id)
    email_log = find_email_log(message_id)
    return unless email_log

    organisation = email_log.notification&.organisation
    unless organisation
      Rails.logger.warn "No organisation found for EmailLog #{email_log.id}"
      return
    end

    ActsAsTenant.with_tenant(organisation) do
      process_webhook_event(email_log, provider, event_type, payload)
    end
  rescue StandardError => e
    Rails.logger.error "Failed to process email webhook: #{e.message}"
    Rails.logger.error "Provider: #{provider}, Event: #{event_type}, MessageID: #{message_id}"
    raise
  end

  private

  def find_email_log(message_id)
    log = ActsAsTenant.without_tenant do
      EmailLog
        .for_webhook_processing
        .find_by(provider_message_id: message_id)
    end

    Rails.logger.warn "EmailLog not found for message_id: #{message_id}" unless log
    log
  end

  def process_webhook_event(email_log, provider, event_type, payload)
    case event_type.to_s.downcase
    when 'bounce', 'bounced'
      process_bounce(email_log, provider, payload)
    when 'complaint', 'spamcomplaint', 'spam'
      process_complaint(email_log, provider, payload)
    when 'delivered', 'delivery'
      process_delivery(email_log, provider, payload)
    when 'open', 'opened'
      process_open(email_log, provider, payload)
    when 'click', 'clicked'
      process_click(email_log, provider, payload)
    when 'unsubscribe', 'unsubscribed'
      process_unsubscribe(email_log)
    when 'deferred', 'delayed'
      process_deferred(email_log, provider, payload)
    else
      Rails.logger.info "Unknown email event type: #{event_type} from #{provider}"
    end
  end

  def process_bounce(email_log, provider, payload)
    bounce_data = extract_bounce_data(provider, payload)
    EmailLog.record_bounce!(email_log.provider_message_id, bounce_data)
    Rails.logger.warn "Email bounced: #{bounce_data[:reason]} (#{bounce_data[:type]})"
  end

  def process_complaint(email_log, provider, payload)
    complaint_data = extract_complaint_data(provider, payload)
    EmailLog.record_complaint!(email_log.provider_message_id, complaint_data)
    Rails.logger.warn "Email spam complaint from #{email_log.notification.recipient.email}"
  end

  def process_delivery(email_log, provider, payload)
    delivery_data = { delivery_time: extract_delivery_time(provider, payload) }
    EmailLog.record_delivery!(email_log.provider_message_id, delivery_data)
  end

  def process_open(email_log, provider, payload)
    open_data = extract_open_data(provider, payload)
    EmailLog.record_open!(email_log.provider_message_id, open_data)
  end

  def process_click(email_log, provider, payload)
    click_data = extract_click_data(provider, payload)
    EmailLog.record_click!(email_log.provider_message_id, click_data)
  end

  def process_unsubscribe(email_log)
    email_log.update!(
      status: :unsubscribed,
      metadata: email_log.metadata.merge(
        'unsubscribed_at' => Time.current.iso8601,
        'unsubscribe_method' => 'provider_webhook'
      )
    )
    email_log.disable_single_event_email_notification!
  end

  def process_deferred(email_log, provider, payload)
    defer_data = extract_defer_data(provider, payload)
    email_log.update!(
      status: :deferred,
      metadata: email_log.metadata.merge(
        'deferred_at' => Time.current.iso8601,
        'defer_reason' => defer_data[:reason]
      )
    )
  end

  # Provider-specific data extraction

  def extract_bounce_data(provider, payload)
    case provider
    when 'postmark'
      {
        type: payload['Type'] == 'HardBounce' ? 'Permanent' : 'Temporary',
        reason: payload['Description'],
        diagnostic_code: payload['Details']
      }
    when 'sendgrid'
      {
        type: payload['type'] == 'bounce' ? 'Permanent' : 'Temporary',
        reason: payload['reason'],
        diagnostic_code: payload['status']
      }
    when 'mailgun'
      {
        type: payload['severity'] == 'permanent' ? 'Permanent' : 'Temporary',
        reason: payload['reason'],
        diagnostic_code: payload['code']
      }
    else
      {
        type: 'Unknown',
        reason: payload['reason'] || 'Unknown bounce',
        diagnostic_code: payload['code'] || payload['status']
      }
    end
  end

  def extract_complaint_data(provider, payload)
    user_agent = case provider
                 when 'postmark' then payload['Details']
                 when 'sendgrid' then payload['useragent']
                 when 'mailgun' then payload['user-agent']
                 else payload['user_agent'] || payload['useragent']
                 end
    { type: 'spam', user_agent: user_agent }
  end

  def extract_open_data(provider, payload)
    case provider
    when 'postmark'
      {
        ip: payload['Geo']&.dig('IP'),
        user_agent: payload['UserAgent'],
        city: payload['Geo']&.dig('City'),
        country: payload['Geo']&.dig('Country')
      }
    when 'sendgrid'
      { ip: payload['ip'], user_agent: payload['useragent'] }
    when 'mailgun'
      {
        ip: payload['ip'],
        user_agent: payload['user-agent'],
        city: payload['city'],
        country: payload['country']
      }
    else
      { ip: payload['ip'], user_agent: payload['user_agent'] || payload['useragent'] }
    end
  end

  def extract_click_data(provider, payload)
    url = case provider
          when 'postmark' then payload['OriginalLink']
          else payload['url'] || payload['link']
          end
    extract_open_data(provider, payload).merge(url: url)
  end

  def extract_delivery_time(provider, payload)
    case provider
    when 'postmark' then payload['DeliveredAt']
    when 'sendgrid', 'mailgun' then payload['timestamp']
    else Time.current.iso8601
    end
  end

  def extract_defer_data(provider, payload)
    reason = case provider
             when 'postmark' then payload['Description']
             when 'sendgrid' then payload['response']
             when 'mailgun' then payload['description']
             else payload['reason'] || 'Temporary delivery failure'
             end
    { reason: reason }
  end
end
