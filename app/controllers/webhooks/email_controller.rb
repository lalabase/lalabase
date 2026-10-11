# frozen_string_literal: true

module Webhooks
  # Processes webhooks from email providers (Postmark, SendGrid, Mailgun).
  #
  # Providers send webhooks on bounces, opens, clicks, spam complaints, etc.
  # This controller validates signatures and delegates the processing
  # to EmailWebhookProcessorJob.

  class EmailController < ApplicationController
    KNOWN_PROVIDERS = %w[postmark sendgrid mailgun].freeze

    skip_before_action :verify_authenticity_token
    skip_before_action :authenticate_user!

    # Generic endpoint with auto-detection
    def webhook
      body_string = read_request_body
      provider = determine_provider

      unless valid_signature?(provider, body_string)
        log_invalid_signature(provider)
        return render json: { error: 'Invalid signature' }, status: :unauthorized
      end

      payload = JSON.parse(body_string)
      event_type = extract_event_type(provider, payload)
      message_id = extract_message_id(provider, payload)

      EmailWebhookProcessorJob.perform_later(provider, event_type, payload, message_id)
      render json: { status: 'ok' }, status: :ok
    rescue JSON::ParserError
      render json: { error: 'Invalid JSON' }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error "Email webhook processing failed: #{e.message}"
      render json: { error: 'Processing failed' }, status: :internal_server_error
    end

    # Provider-specific endpoints
    def postmark
      process_provider_webhook('postmark')
    end

    def sendgrid
      process_provider_webhook('sendgrid')
    end

    def mailgun
      process_provider_webhook('mailgun')
    end

    private

    # --- Request handling ---

    def read_request_body
      body = request.body.read
      request.body.rewind
      body
    end

    def process_provider_webhook(provider)
      body_string = read_request_body

      unless valid_signature?(provider, body_string)
        log_invalid_signature(provider)
        return render json: { error: 'Invalid signature' }, status: :unauthorized
      end

      payload = JSON.parse(body_string)
      enqueue_provider_jobs(provider, payload)
      render json: { status: 'ok' }
    rescue JSON::ParserError
      render json: { error: 'Invalid JSON' }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error "#{provider} webhook processing failed: #{e.message}"
      render json: { error: 'Processing failed' }, status: :internal_server_error
    end

    def enqueue_provider_jobs(provider, payload)
      case provider
      when 'postmark'
        enqueue_postmark_event(payload)
      when 'sendgrid'
        enqueue_sendgrid_events(payload)
      when 'mailgun'
        EmailWebhookProcessorJob.perform_later('mailgun', payload['event'], payload, payload['Message-Id'])
      end
    end

    def enqueue_postmark_event(payload)
      event_mapping = {
        'Bounce' => 'bounce',
        'SpamComplaint' => 'complaint',
        'Delivery' => 'delivery',
        'Open' => 'opened',
        'Click' => 'clicked'
      }.freeze

      event_type = event_mapping[payload['Type']]
      return Rails.logger.info("Unknown Postmark event type: #{payload['Type']}") unless event_type

      EmailWebhookProcessorJob.perform_later('postmark', event_type, payload, payload['MessageID'])
    end

    def enqueue_sendgrid_events(payload)
      events = payload.is_a?(Array) ? payload : [payload]

      events.each do |event|
        EmailWebhookProcessorJob.perform_later(
          'sendgrid', event['event'], event, event['sg_message_id'] || event['smtp-id']
        )
      end
    end

    # --- Provider detection ---

    def determine_provider
      detect_provider_from_subdomain ||
        detect_provider_from_user_agent ||
        detect_provider_from_headers ||
        'unknown'
    end

    def detect_provider_from_subdomain
      subdomain = request.subdomain
      subdomain if KNOWN_PROVIDERS.include?(subdomain)
    end

    def detect_provider_from_user_agent
      user_agent = request.headers['User-Agent'].to_s.downcase
      KNOWN_PROVIDERS.find { |p| user_agent.include?(p) }
    end

    def detect_provider_from_headers
      return 'postmark' if request.headers['X-Postmark-Token'].present?
      return 'sendgrid' if request.headers['X-Twilio-Email-Event-Webhook-Signature'].present?
      return 'mailgun' if request.headers['X-Mailgun-Signature'].present?

      nil
    end

    # --- Signature validation ---

    def valid_signature?(provider, body_string)
      case provider
      when 'postmark'  then validate_postmark_signature
      when 'sendgrid'  then validate_sendgrid_signature(body_string)
      when 'mailgun'   then validate_mailgun_signature(body_string)
      else
        Rails.logger.warn "SECURITY: Webhook von unbekanntem Provider abgelehnt: #{provider}"
        false
      end
    end

    def validate_postmark_signature
      expected_token = Rails.application.credentials.dig(:postmark, :webhook_token)

      return false if production_missing_credentials?('Postmark webhook token', expected_token)
      return true if dev_skip_validation?(expected_token)

      received_token = request.headers['X-Postmark-Token']
      return log_missing_header('X-Postmark-Token') if received_token.blank?

      ActiveSupport::SecurityUtils.secure_compare(expected_token.to_s, received_token.to_s).tap do |valid|
        Rails.logger.warn "Invalid Postmark webhook token from #{request.remote_ip}" unless valid
      end
    end

    def validate_sendgrid_signature(body_string)
      public_key_base64 = Rails.application.credentials.dig(:sendgrid, :webhook_public_key)

      return false if production_missing_credentials?('SendGrid webhook public key', public_key_base64)
      return true if dev_skip_validation?(public_key_base64)

      signature = request.headers['X-Twilio-Email-Event-Webhook-Signature']
      timestamp = request.headers['X-Twilio-Email-Event-Webhook-Timestamp']

      return log_missing_header('SendGrid webhook signature/timestamp') if signature.blank? || timestamp.blank?
      return false if timestamp_expired?(timestamp.to_i, tolerance: 600)

      verify_sendgrid_ecdsa(public_key_base64, signature, timestamp, body_string)
    rescue OpenSSL::PKey::ECError, ArgumentError => e
      Rails.logger.error "SendGrid signature validation error: #{e.message}"
      false
    rescue StandardError => e
      Rails.logger.error "Unexpected error validating SendGrid signature: #{e.message}"
      false
    end

    def validate_mailgun_signature(body_string)
      webhook_signing_key = Rails.application.credentials.dig(:mailgun, :webhook_signing_key)

      return false if production_missing_credentials?('Mailgun webhook signing key', webhook_signing_key)
      return true if dev_skip_validation?(webhook_signing_key)

      signature = request.headers['X-Mailgun-Signature-256']
      return log_missing_header('X-Mailgun-Signature-256') if signature.blank?

      parsed_params = Rack::Utils.parse_nested_query(body_string.to_s)
      timestamp = parsed_params['timestamp']
      token = parsed_params['token']

      return log_missing_header('Mailgun timestamp/token') if timestamp.blank? || token.blank?
      return false if timestamp_expired?(timestamp.to_i, tolerance: 900)

      expected = OpenSSL::HMAC.hexdigest('sha256', webhook_signing_key, "#{timestamp}#{token}")
      ActiveSupport::SecurityUtils.secure_compare(signature, expected).tap do |valid|
        Rails.logger.warn "Invalid Mailgun webhook signature from #{request.remote_ip}" unless valid
      end
    rescue StandardError => e
      Rails.logger.error "Error validating Mailgun signature: #{e.message}"
      false
    end

    # --- Signature validation helpers ---

    def production_missing_credentials?(name, value)
      return false unless Rails.env.production? && value.blank?

      Rails.logger.error "SECURITY ALERT: #{name} not configured in production!"
      true
    end

    def dev_skip_validation?(credential)
      !Rails.env.production? && credential.blank?
    end

    def timestamp_expired?(event_timestamp, tolerance:)
      delta = (Time.current.to_i - event_timestamp).abs
      if delta > tolerance
        Rails.logger.warn "Webhook timestamp expired from #{request.remote_ip}: delta=#{delta}s, tolerance=#{tolerance}s"
        true
      else
        false
      end
    end

    def log_missing_header(header_name)
      Rails.logger.warn "Missing #{header_name} from #{request.remote_ip}"
      false
    end

    def log_invalid_signature(provider)
      Rails.logger.warn "Invalid webhook signature from #{provider}: #{request.remote_ip}"
    end

    def verify_sendgrid_ecdsa(public_key_base64, signature, timestamp, body_string)
      public_key_der = Base64.decode64(public_key_base64)
      public_key = OpenSSL::PKey::EC.new(public_key_der)
      payload_to_verify = timestamp + body_string.to_s
      signature_bytes = Base64.decode64(signature)

      public_key.verify('sha256', signature_bytes, payload_to_verify).tap do |valid|
        Rails.logger.warn "Invalid SendGrid webhook signature from #{request.remote_ip}" unless valid
      end
    end

    # --- Payload extraction ---

    def extract_event_type(provider, payload)
      case provider
      when 'postmark' then payload['Type']&.downcase
      when 'sendgrid', 'mailgun' then payload['event']
      else payload['event'] || payload['type'] || 'unknown'
      end
    end

    def extract_message_id(provider, payload)
      case provider
      when 'postmark' then payload['MessageID']
      when 'sendgrid' then payload['sg_message_id'] || payload['smtp-id']
      when 'mailgun' then payload['Message-Id']
      else payload['message_id'] || payload['id']
      end
    end
  end
end
