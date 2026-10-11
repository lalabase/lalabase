# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::EmailController', :ci_guard, type: :request do
  include ActiveJob::TestHelper

  before { ActiveJob::Base.queue_adapter = :test }

  # Webhook endpoints are public — no user sign-in needed.
  # The controller unconditionally skips CSRF and authentication.

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  def post_webhook(path, body:, headers: {})
    post path,
         params: body,
         headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }.merge(headers)
  end

  def json_body
    JSON.parse(response.body)
  end

  # ---------------------------------------------------------------------------
  # POST /webhooks/email (generic endpoint with auto-detection)
  # ---------------------------------------------------------------------------
  describe 'POST /webhooks/email' do
    context 'with valid Postmark webhook' do
      let(:payload) { { 'Type' => 'Bounce', 'MessageID' => 'msg-123' }.to_json }

      it 'accepts the webhook and returns ok' do
        post_webhook '/webhooks/email',
                     body: payload,
                     headers: { 'X-Postmark-Token' => 'test-token' }

        expect(response).to have_http_status(:ok)
        expect(json_body['status']).to eq('ok')
      end

      it 'enqueues EmailWebhookProcessorJob' do
        expect do
          post_webhook '/webhooks/email',
                       body: payload,
                       headers: { 'X-Postmark-Token' => 'test-token' }
        end.to have_enqueued_job(EmailWebhookProcessorJob)
      end
    end

    context 'with invalid JSON body' do
      it 'returns 400 bad request' do
        post_webhook '/webhooks/email',
                     body: 'not-valid-json{{{',
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response).to have_http_status(:bad_request)
        expect(json_body['error']).to eq('Invalid JSON')
      end

      it 'does not enqueue any job' do
        expect do
          post_webhook '/webhooks/email',
                       body: '{broken',
                       headers: { 'User-Agent' => 'Postmark' }
        end.not_to have_enqueued_job(EmailWebhookProcessorJob)
      end
    end

    context 'with empty body' do
      it 'returns 400 for empty string' do
        post_webhook '/webhooks/email',
                     body: '',
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'with unknown provider' do
      it 'rejects with 401 unauthorized' do
        post_webhook '/webhooks/email',
                     body: { event: 'bounce' }.to_json

        expect(response).to have_http_status(:unauthorized)
        expect(json_body['error']).to eq('Invalid signature')
      end
    end

    # --- Provider detection ---

    describe 'provider detection' do
      it 'detects Postmark via User-Agent header' do
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'Delivery', 'MessageID' => 'pm-1' }.to_json,
                     headers: { 'User-Agent' => 'Postmark Agent/1.0' }

        expect(response).to have_http_status(:ok)
      end

      it 'detects SendGrid via User-Agent header' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'sg_message_id' => 'sg-1' }.to_json,
                     headers: { 'User-Agent' => 'SendGrid/7.0' }

        expect(response).to have_http_status(:ok)
      end

      it 'detects Mailgun via User-Agent header' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'Message-Id' => 'mg-1' }.to_json,
                     headers: { 'User-Agent' => 'mailgun-client/2.0' }

        expect(response).to have_http_status(:ok)
      end

      it 'detects Postmark via X-Postmark-Token header' do
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'Delivery', 'MessageID' => 'pm-2' }.to_json,
                     headers: { 'X-Postmark-Token' => 'some-token' }

        expect(response).to have_http_status(:ok)
      end

      it 'detects SendGrid via signature header' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'sg_message_id' => 'sg-2' }.to_json,
                     headers: { 'X-Twilio-Email-Event-Webhook-Signature' => 'sig' }

        expect(response).to have_http_status(:ok)
      end

      it 'detects Mailgun via signature header' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'Message-Id' => 'mg-2' }.to_json,
                     headers: { 'X-Mailgun-Signature' => 'sig' }

        expect(response).to have_http_status(:ok)
      end
    end

    # --- Event type extraction ---

    describe 'event type extraction' do
      it 'extracts Postmark event type from Type field and enqueues job' do
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'SpamComplaint', 'MessageID' => 'pm-3' }.to_json,
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'spamcomplaint', anything, 'pm-3'
        )
      end

      it 'extracts SendGrid event type from event field' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'bounce', 'sg_message_id' => 'sg-3' }.to_json,
                     headers: { 'User-Agent' => 'SendGrid' }

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'sendgrid', 'bounce', anything, 'sg-3'
        )
      end
    end

    # --- Message ID extraction ---

    describe 'message ID extraction' do
      it 'uses MessageID for Postmark' do
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'Delivery', 'MessageID' => 'pm-unique-id' }.to_json,
                     headers: { 'User-Agent' => 'Postmark' }

        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'delivery', anything, 'pm-unique-id'
        )
      end

      it 'uses sg_message_id for SendGrid' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'sg_message_id' => 'sg-unique-id' }.to_json,
                     headers: { 'User-Agent' => 'SendGrid' }

        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'sendgrid', 'delivered', anything, 'sg-unique-id'
        )
      end

      it 'falls back to smtp-id for SendGrid when sg_message_id is missing' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'smtp-id' => 'smtp-fallback-id' }.to_json,
                     headers: { 'User-Agent' => 'SendGrid' }

        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'sendgrid', 'delivered', anything, 'smtp-fallback-id'
        )
      end

      it 'uses Message-Id for Mailgun' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'delivered', 'Message-Id' => 'mg-unique-id' }.to_json,
                     headers: { 'User-Agent' => 'Mailgun' }

        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'mailgun', 'delivered', anything, 'mg-unique-id'
        )
      end

      it 'handles missing message ID gracefully' do
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'Delivery' }.to_json,
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'delivery', anything, nil
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /webhooks/email/postmark
  # ---------------------------------------------------------------------------
  describe 'POST /webhooks/email/postmark' do
    context 'Bounce event' do
      it 'enqueues job with bounce event type' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Bounce', 'MessageID' => 'pm-bounce-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'bounce', anything, 'pm-bounce-1'
        )
      end
    end

    context 'SpamComplaint event' do
      it 'enqueues job with complaint event type' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'SpamComplaint', 'MessageID' => 'pm-spam-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'complaint', anything, 'pm-spam-1'
        )
      end
    end

    context 'Delivery event' do
      it 'enqueues job with delivery event type' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Delivery', 'MessageID' => 'pm-del-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'delivery', anything, 'pm-del-1'
        )
      end
    end

    context 'Open event' do
      it 'enqueues job with opened event type' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Open', 'MessageID' => 'pm-open-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'opened', anything, 'pm-open-1'
        )
      end
    end

    context 'Click event' do
      it 'enqueues job with clicked event type' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Click', 'MessageID' => 'pm-click-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'postmark', 'clicked', anything, 'pm-click-1'
        )
      end
    end

    context 'unknown event type' do
      it 'returns ok but does not enqueue a job' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'SomethingNew', 'MessageID' => 'pm-unknown-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end
    end

    context 'invalid JSON' do
      it 'returns 400 bad request with error message' do
        post_webhook '/webhooks/email/postmark', body: 'not-json'

        expect(response).to have_http_status(:bad_request)
        expect(json_body['error']).to eq('Invalid JSON')
      end
    end

    context 'with nil Type field' do
      it 'treats as unknown event type and returns ok' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'MessageID' => 'pm-nil-type' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /webhooks/email/sendgrid
  # ---------------------------------------------------------------------------
  describe 'POST /webhooks/email/sendgrid' do
    context 'single event' do
      it 'enqueues a single job' do
        post_webhook '/webhooks/email/sendgrid',
                     body: { 'event' => 'bounce', 'sg_message_id' => 'sg-bounce-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'sendgrid', 'bounce', anything, 'sg-bounce-1'
        )
      end
    end

    context 'batch events (array payload)' do
      it 'enqueues one job per event' do
        payload = [
          { 'event' => 'delivered', 'sg_message_id' => 'sg-batch-1' },
          { 'event' => 'open', 'sg_message_id' => 'sg-batch-2' },
          { 'event' => 'bounce', 'sg_message_id' => 'sg-batch-3' }
        ].to_json

        expect do
          post_webhook '/webhooks/email/sendgrid', body: payload
        end.to have_enqueued_job(EmailWebhookProcessorJob).exactly(3).times

        expect(response).to have_http_status(:ok)
      end
    end

    context 'empty array' do
      it 'returns ok without enqueuing jobs' do
        post_webhook '/webhooks/email/sendgrid', body: [].to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end
    end

    context 'event without message ID' do
      it 'still enqueues the job with nil message_id' do
        post_webhook '/webhooks/email/sendgrid',
                     body: { 'event' => 'bounce' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'sendgrid', 'bounce', anything, nil
        )
      end
    end

    context 'invalid JSON' do
      it 'returns 400 bad request with error message' do
        post_webhook '/webhooks/email/sendgrid', body: '<<<invalid'

        expect(response).to have_http_status(:bad_request)
        expect(json_body['error']).to eq('Invalid JSON')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /webhooks/email/mailgun
  # ---------------------------------------------------------------------------
  describe 'POST /webhooks/email/mailgun' do
    context 'valid event' do
      it 'enqueues a job' do
        post_webhook '/webhooks/email/mailgun',
                     body: { 'event' => 'delivered', 'Message-Id' => 'mg-del-1' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'mailgun', 'delivered', anything, 'mg-del-1'
        )
      end
    end

    context 'event without Message-Id' do
      it 'enqueues the job with nil message_id' do
        post_webhook '/webhooks/email/mailgun',
                     body: { 'event' => 'bounced' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'mailgun', 'bounced', anything, nil
        )
      end
    end

    context 'event without event type' do
      it 'enqueues the job with nil event_type' do
        post_webhook '/webhooks/email/mailgun',
                     body: { 'Message-Id' => 'mg-no-event' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with(
          'mailgun', nil, anything, 'mg-no-event'
        )
      end
    end

    context 'invalid JSON' do
      it 'returns 400 bad request with error message' do
        post_webhook '/webhooks/email/mailgun', body: 'broken-json'

        expect(response).to have_http_status(:bad_request)
        expect(json_body['error']).to eq('Invalid JSON')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Signature Validation
  # ---------------------------------------------------------------------------
  describe 'signature validation' do
    describe 'Postmark' do
      context 'with configured token' do
        let(:webhook_token) { 'valid-postmark-token-12345' }

        before do
          allow(Rails.application.credentials).to receive(:dig)
            .with(:postmark, :webhook_token).and_return(webhook_token)
        end

        it 'accepts request with valid token' do
          post_webhook '/webhooks/email',
                       body: { 'Type' => 'Delivery', 'MessageID' => 'pm-sig-1' }.to_json,
                       headers: { 'X-Postmark-Token' => webhook_token }

          expect(response).to have_http_status(:ok)
        end

        it 'rejects request with wrong token' do
          post_webhook '/webhooks/email',
                       body: { 'Type' => 'Delivery', 'MessageID' => 'pm-sig-2' }.to_json,
                       headers: { 'X-Postmark-Token' => 'wrong-token' }

          expect(response).to have_http_status(:unauthorized)
        end

        it 'rejects request without token header' do
          post_webhook '/webhooks/email',
                       body: { 'Type' => 'Delivery', 'MessageID' => 'pm-sig-3' }.to_json,
                       headers: { 'User-Agent' => 'Postmark' }

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'in production without configured token' do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
          allow(Rails.application.credentials).to receive(:dig)
            .with(:postmark, :webhook_token).and_return(nil)
        end

        it 'rejects all requests' do
          post_webhook '/webhooks/email',
                       body: { 'Type' => 'Delivery', 'MessageID' => 'pm-prod-1' }.to_json,
                       headers: { 'X-Postmark-Token' => 'any-token', 'User-Agent' => 'Postmark' }

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    describe 'SendGrid' do
      context 'with configured key' do
        before do
          allow(Rails.application.credentials).to receive(:dig)
            .with(:sendgrid, :webhook_public_key).and_return('test-public-key')
        end

        it 'rejects request with missing signature headers' do
          post_webhook '/webhooks/email',
                       body: { 'event' => 'delivered' }.to_json,
                       headers: { 'User-Agent' => 'SendGrid' }

          expect(response).to have_http_status(:unauthorized)
        end

        it 'rejects request with expired timestamp' do
          post_webhook '/webhooks/email',
                       body: { 'event' => 'delivered' }.to_json,
                       headers: {
                         'User-Agent' => 'SendGrid',
                         'X-Twilio-Email-Event-Webhook-Signature' => 'sig',
                         'X-Twilio-Email-Event-Webhook-Timestamp' => (Time.current.to_i - 700).to_s
                       }

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'in production without configured key' do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
          allow(Rails.application.credentials).to receive(:dig)
            .with(:sendgrid, :webhook_public_key).and_return(nil)
        end

        it 'rejects all requests' do
          post_webhook '/webhooks/email',
                       body: { 'event' => 'delivered' }.to_json,
                       headers: {
                         'User-Agent' => 'SendGrid',
                         'X-Twilio-Email-Event-Webhook-Signature' => 'sig',
                         'X-Twilio-Email-Event-Webhook-Timestamp' => Time.current.to_i.to_s
                       }

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    describe 'Mailgun' do
      context 'with configured signing key' do
        let(:signing_key) { 'mailgun-signing-key-12345' }

        before do
          allow(Rails.application.credentials).to receive(:dig)
            .with(:mailgun, :webhook_signing_key).and_return(signing_key)
        end

        it 'rejects request without signature header' do
          post_webhook '/webhooks/email',
                       body: { 'event' => 'delivered' }.to_json,
                       headers: { 'User-Agent' => 'Mailgun' }

          expect(response).to have_http_status(:unauthorized)
        end

        it 'rejects request with expired timestamp' do
          old_timestamp = (Time.current.to_i - 1000).to_s
          token = SecureRandom.hex(32)
          expected_sig = OpenSSL::HMAC.hexdigest('sha256', signing_key, "#{old_timestamp}#{token}")

          post_webhook '/webhooks/email',
                       body: { 'event' => 'delivered' }.to_json,
                       headers: {
                         'User-Agent' => 'Mailgun',
                         'X-Mailgun-Signature-256' => expected_sig
                       }

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'in production without configured key' do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
          allow(Rails.application.credentials).to receive(:dig)
            .with(:mailgun, :webhook_signing_key).and_return(nil)
        end

        it 'rejects all requests' do
          post_webhook '/webhooks/email',
                       body: { 'event' => 'delivered' }.to_json,
                       headers: {
                         'User-Agent' => 'Mailgun',
                         'X-Mailgun-Signature-256' => 'any-sig'
                       }

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    context 'unknown provider' do
      it 'always rejects with 401' do
        post_webhook '/webhooks/email',
                     body: { 'event' => 'bounce' }.to_json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases & Security
  # ---------------------------------------------------------------------------
  describe 'edge cases' do
    context 'very large payload' do
      it 'handles large JSON payload without crashing' do
        large_payload = { 'Type' => 'Delivery', 'MessageID' => 'pm-large', 'data' => 'x' * 100_000 }.to_json

        post_webhook '/webhooks/email',
                     body: large_payload,
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response).to have_http_status(:ok)
      end
    end

    context 'payload with unexpected data types' do
      it 'handles numeric Type field without enqueuing (no matching event)' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 123, 'MessageID' => 'pm-numeric' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end

      it 'handles null event type without enqueuing (no matching event)' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => nil, 'MessageID' => 'pm-null' }.to_json

        expect(response).to have_http_status(:ok)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end
    end

    context 'CSRF protection' do
      it 'does not require CSRF token for webhook endpoints' do
        post '/webhooks/email',
             params: { 'Type' => 'Delivery', 'MessageID' => 'csrf-test' }.to_json,
             headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }

        # Must not get 422 (ActionController::InvalidAuthenticityToken)
        expect(response.status).not_to eq(422)
      end
    end

    context 'authentication bypass' do
      it 'does not require user authentication' do
        # No sign_in call — should still work
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'Delivery', 'MessageID' => 'auth-test' }.to_json,
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response.status).not_to eq(302) # No Devise redirect
        expect(response).to have_http_status(:ok)
      end
    end

    context 'content type handling' do
      it 'returns JSON response' do
        post_webhook '/webhooks/email',
                     body: { 'Type' => 'Delivery', 'MessageID' => 'ct-1' }.to_json,
                     headers: { 'User-Agent' => 'Postmark' }

        expect(response.content_type).to include('application/json')
      end
    end

    context 'concurrent requests' do
      it 'handles multiple sequential webhook calls' do
        3.times do |i|
          post_webhook '/webhooks/email',
                       body: { 'Type' => 'Delivery', 'MessageID' => "pm-concurrent-#{i}" }.to_json,
                       headers: { 'User-Agent' => 'Postmark' }

          expect(response).to have_http_status(:ok)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Response format consistency
  # ---------------------------------------------------------------------------
  describe 'response format' do
    it 'returns { status: "ok" } on success' do
      post_webhook '/webhooks/email',
                   body: { 'Type' => 'Delivery', 'MessageID' => 'fmt-1' }.to_json,
                   headers: { 'User-Agent' => 'Postmark' }

      expect(json_body).to eq('status' => 'ok')
    end

    it 'returns { error: ... } on auth failure' do
      post_webhook '/webhooks/email',
                   body: { 'event' => 'bounce' }.to_json

      expect(json_body).to have_key('error')
    end

    it 'returns { error: ... } on parse error' do
      post_webhook '/webhooks/email',
                   body: 'invalid',
                   headers: { 'User-Agent' => 'Postmark' }

      expect(json_body).to have_key('error')
    end

    it 'provider endpoints return same structure as generic endpoint' do
      post_webhook '/webhooks/email/postmark',
                   body: { 'Type' => 'Delivery', 'MessageID' => 'fmt-2' }.to_json

      expect(json_body).to have_key('status')
    end
  end

  # ---------------------------------------------------------------------------
  # REGRESSION GUARD: signature verification on the provider-specific endpoints
  # ---------------------------------------------------------------------------
  #
  # Type: security regression test (request spec).
  #
  # Why: The provider-specific actions (#postmark/#sendgrid/#mailgun)
  # ran through process_provider_webhook, which NEVER verified the signature
  # — an auth bypass: anyone could post forged Bounce/Complaint/Open/Click
  # events and thereby manipulate deliverability, EmailLog state and (via
  # EmailLog#handle_status_change) user notifications.
  # The generic #webhook had the check; the provider paths did not.
  #
  # Contract: If the provider credential is set (i.e. validation active),
  # a forged/missing request MUST be rejected with 401 and must NOT enqueue
  # any job; a correctly signed request stays 200 + job.
  #
  # CRITICAL TEST TRAP: dev_skip_validation? returns true in the test
  # environment as long as the credential is empty — then valid_signature? is always
  # true and a naive 401 test would be green WITHOUT the fix taking effect. That is why
  # these tests stub the respective credential, so that the skip is OFF and
  # the real validation produces the 401.
  describe 'signature enforcement on provider-specific endpoints' do
    describe 'POST /webhooks/email/postmark' do
      let(:webhook_token) { 'configured-postmark-token' }

      before do
        # Credential set => dev_skip_validation? = false => real check active.
        allow(Rails.application.credentials).to receive(:dig)
          .with(:postmark, :webhook_token).and_return(webhook_token)
      end

      # RED before the fix (came through as 200 + job), GREEN after the fix.
      it 'rejects a forged request without the token header (401, no job)' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Bounce', 'MessageID' => 'forged-1' }.to_json

        expect(response).to have_http_status(:unauthorized)
        expect(json_body['error']).to eq('Invalid signature')
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end

      it 'rejects a request with the wrong token (401, no job)' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Bounce', 'MessageID' => 'forged-2' }.to_json,
                     headers: { 'X-Postmark-Token' => 'wrong-token' }

        expect(response).to have_http_status(:unauthorized)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end

      # Counter-check: a correct token must NOT be accidentally blocked along with the rest.
      it 'still accepts a correctly signed request (200, job enqueued)' do
        post_webhook '/webhooks/email/postmark',
                     body: { 'Type' => 'Bounce', 'MessageID' => 'valid-1' }.to_json,
                     headers: { 'X-Postmark-Token' => webhook_token }

        expect(response).to have_http_status(:ok)
        expect(json_body['status']).to eq('ok')
        expect(EmailWebhookProcessorJob).to have_been_enqueued.with('postmark', 'bounce', anything, 'valid-1')
      end
    end

    # SendGrid/Mailgun: real validation active (credential set), but
    # without valid signature headers => must be 401 + no job. Proves that
    # the bypass is closed on all three provider paths.
    describe 'POST /webhooks/email/sendgrid' do
      before do
        allow(Rails.application.credentials).to receive(:dig)
          .with(:sendgrid, :webhook_public_key).and_return('configured-sendgrid-key')
      end

      it 'rejects a forged request without signature headers (401, no job)' do
        post_webhook '/webhooks/email/sendgrid',
                     body: { 'event' => 'bounce', 'sg_message_id' => 'forged-sg-1' }.to_json

        expect(response).to have_http_status(:unauthorized)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end
    end

    describe 'POST /webhooks/email/mailgun' do
      before do
        allow(Rails.application.credentials).to receive(:dig)
          .with(:mailgun, :webhook_signing_key).and_return('configured-mailgun-key')
      end

      it 'rejects a forged request without the signature header (401, no job)' do
        post_webhook '/webhooks/email/mailgun',
                     body: { 'event' => 'bounced', 'Message-Id' => 'forged-mg-1' }.to_json

        expect(response).to have_http_status(:unauthorized)
        expect(EmailWebhookProcessorJob).not_to have_been_enqueued
      end
    end
  end
end
