# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailWebhookProcessorJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let!(:organisation) { create(:organisation) }
  let(:recipient) { create(:user, organisation: organisation) }
  let(:actor) { create(:user, organisation: organisation) }
  let(:message_id) { "msg-#{SecureRandom.hex(8)}" }

  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: recipient,
             actor: actor,
             organisation: organisation,
             event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
             channel: Notifications::Constants::CHANNEL_EMAIL)
    end
  end

  let!(:email_log) do
    ActsAsTenant.with_tenant(organisation) do
      create(:email_log, :sent,
             notification: notification,
             organisation: organisation,
             provider_message_id: message_id,
             metadata: { 'provider' => 'postmark' })
    end
  end

  def perform_job(provider: 'postmark', event_type: 'bounce', payload: {}, msg_id: message_id)
    described_class.new.perform(provider, event_type, payload, msg_id)
  end

  describe 'job configuration' do
    it 'uses the webhooks queue' do
      expect(described_class.new.queue_name).to eq('webhooks')
    end
  end

  describe '#perform' do
    # ---------------------------------------------------------------
    # Edge Case: EmailLog not found
    # ---------------------------------------------------------------
    context 'when EmailLog not found for message_id' do
      it 'logs warning and returns without error' do
        expect do
          perform_job(msg_id: 'nonexistent-message-id')
        end.not_to raise_error
      end

      it 'does not change any EmailLog records' do
        expect do
          perform_job(msg_id: 'nonexistent-message-id')
        end.not_to(change { email_log.reload.status })
      end
    end

    # ---------------------------------------------------------------
    # Edge Case: Orphaned EmailLog (notification/organisation missing)
    # ---------------------------------------------------------------
    context 'when notification has no organisation' do
      it 'logs warning and returns without error' do
        job = described_class.new
        allow(job).to receive(:find_email_log)
          .and_return(instance_double(EmailLog, id: 'orphaned-id', notification: double(organisation: nil)))

        expect do
          job.perform('postmark', 'bounce', {}, 'any-id')
        end.not_to raise_error
      end
    end

    # ---------------------------------------------------------------
    # Edge Case: Unknown event type
    # ---------------------------------------------------------------
    context 'with unknown event type' do
      it 'logs info message' do
        expect(Rails.logger).to receive(:info).with(/Unknown email event type: weird_event from postmark/)
        perform_job(event_type: 'weird_event')
      end

      it 'does not change email_log status' do
        expect do
          perform_job(event_type: 'weird_event')
        end.not_to(change { email_log.reload.status })
      end
    end

    # ---------------------------------------------------------------
    # Tenant Context
    # ---------------------------------------------------------------
    context 'tenant context' do
      it 'sets ActsAsTenant to the email_log organisation during processing' do
        tenant_during_processing = nil

        allow(EmailLog).to receive(:record_bounce!) do |_mid, _data|
          tenant_during_processing = ActsAsTenant.current_tenant
        end

        perform_job(event_type: 'bounce', payload: { 'Description' => 'test' })
        expect(tenant_during_processing).to eq(organisation)
      end
    end

    # ---------------------------------------------------------------
    # Error Handling
    # ---------------------------------------------------------------
    context 'error handling' do
      it 're-raises StandardError for retry mechanism' do
        allow(EmailLog).to receive(:record_bounce!).and_raise(StandardError, 'DB connection lost')

        expect do
          perform_job(event_type: 'bounce')
        end.to raise_error(StandardError, 'DB connection lost')
      end
    end

    # ---------------------------------------------------------------
    # Event Type Normalization (aliases + case-insensitivity)
    # ---------------------------------------------------------------
    describe 'event type normalization' do
      before do
        # Stub all record methods to isolate normalization testing
        allow(EmailLog).to receive(:record_bounce!)
        allow(EmailLog).to receive(:record_complaint!)
        allow(EmailLog).to receive(:record_delivery!)
        allow(EmailLog).to receive(:record_open!)
        allow(EmailLog).to receive(:record_click!)
      end

      {
        'bounce' => :record_bounce!,
        'bounced' => :record_bounce!,
        'BOUNCE' => :record_bounce!,
        'Bounced' => :record_bounce!,
        'complaint' => :record_complaint!,
        'spamcomplaint' => :record_complaint!,
        'spam' => :record_complaint!,
        'SPAM' => :record_complaint!,
        'delivered' => :record_delivery!,
        'delivery' => :record_delivery!,
        'DELIVERED' => :record_delivery!,
        'open' => :record_open!,
        'opened' => :record_open!,
        'OPEN' => :record_open!,
        'click' => :record_click!,
        'clicked' => :record_click!,
        'CLICKED' => :record_click!
      }.each do |input_type, expected_method|
        it "routes '#{input_type}' to EmailLog.#{expected_method}" do
          expect(EmailLog).to receive(expected_method)
          perform_job(event_type: input_type)
        end
      end

      %w[unsubscribe unsubscribed UNSUBSCRIBE].each do |input_type|
        it "routes '#{input_type}' to process_unsubscribe" do
          expect { perform_job(event_type: input_type) }
            .to change { email_log.reload.status }.to('unsubscribed')
        end
      end

      %w[deferred delayed DEFERRED].each do |input_type|
        it "routes '#{input_type}' to process_deferred" do
          expect { perform_job(event_type: input_type) }
            .to change { email_log.reload.status }.to('deferred')
        end
      end
    end

    # ---------------------------------------------------------------
    # BOUNCE EVENTS
    # ---------------------------------------------------------------
    describe 'bounce events' do
      it 'updates email_log status to bounced' do
        perform_job(
          event_type: 'bounce',
          payload: { 'Type' => 'HardBounce', 'Description' => 'Mailbox not found' }
        )

        email_log.reload
        expect(email_log.status).to eq('bounced')
      end

      it 'stores bounce metadata' do
        perform_job(
          event_type: 'bounce',
          payload: { 'Type' => 'HardBounce', 'Description' => 'Mailbox not found', 'Details' => '550 5.1.1' }
        )

        email_log.reload
        expect(email_log.metadata).to include(
          'bounce_type' => 'Permanent',
          'bounce_reason' => 'Mailbox not found',
          'diagnostic_code' => '550 5.1.1'
        )
      end

      context 'permanent (hard) bounce' do
        it 'disables all email notifications for the recipient' do
          expect_any_instance_of(EmailLog).to receive(:disable_all_email_notifications!)

          perform_job(
            event_type: 'bounce',
            payload: { 'Type' => 'HardBounce', 'Description' => 'Mailbox not found' }
          )
        end
      end

      context 'temporary (soft) bounce' do
        it 'does not disable email notifications immediately' do
          expect_any_instance_of(EmailLog).not_to receive(:disable_all_email_notifications!)

          perform_job(
            event_type: 'bounce',
            payload: { 'Type' => 'SoftBounce', 'Description' => 'Mailbox full' }
          )
        end

        it 'records bounce type as Temporary' do
          perform_job(
            event_type: 'bounce',
            payload: { 'Type' => 'SoftBounce', 'Description' => 'Mailbox full' }
          )

          expect(email_log.reload.metadata['bounce_type']).to eq('Temporary')
        end
      end

      context 'provider-specific extraction' do
        it 'extracts postmark bounce data' do
          perform_job(
            provider: 'postmark',
            event_type: 'bounce',
            payload: { 'Type' => 'HardBounce', 'Description' => 'Bad destination', 'Details' => '550' }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'bounce_type' => 'Permanent',
            'bounce_reason' => 'Bad destination',
            'diagnostic_code' => '550'
          )
        end

        it 'extracts sendgrid bounce data' do
          perform_job(
            provider: 'sendgrid',
            event_type: 'bounce',
            payload: { 'type' => 'bounce', 'reason' => 'Invalid address', 'status' => '550' }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'bounce_type' => 'Permanent',
            'bounce_reason' => 'Invalid address',
            'diagnostic_code' => '550'
          )
        end

        it 'extracts mailgun bounce data' do
          perform_job(
            provider: 'mailgun',
            event_type: 'bounce',
            payload: { 'severity' => 'permanent', 'reason' => 'No such user', 'code' => '550' }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'bounce_type' => 'Permanent',
            'bounce_reason' => 'No such user',
            'diagnostic_code' => '550'
          )
        end

        it 'uses fallback for unknown provider' do
          perform_job(
            provider: 'unknown_provider',
            event_type: 'bounce',
            payload: { 'reason' => 'Something went wrong', 'code' => '421' }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'bounce_type' => 'Unknown',
            'bounce_reason' => 'Something went wrong',
            'diagnostic_code' => '421'
          )
        end

        it 'uses default reason for unknown provider with empty payload' do
          perform_job(
            provider: 'unknown_provider',
            event_type: 'bounce',
            payload: {}
          )

          email_log.reload
          expect(email_log.metadata['bounce_reason']).to eq('Unknown bounce')
        end
      end
    end

    # ---------------------------------------------------------------
    # COMPLAINT EVENTS
    # ---------------------------------------------------------------
    describe 'complaint events' do
      it 'updates email_log status to complaint' do
        perform_job(
          event_type: 'complaint',
          payload: { 'Details' => 'Mozilla/5.0' }
        )

        expect(email_log.reload.status).to eq('complaint')
      end

      it 'stores complaint metadata' do
        perform_job(
          event_type: 'complaint',
          payload: { 'Details' => 'Mozilla/5.0' }
        )

        email_log.reload
        expect(email_log.metadata).to include(
          'complaint_type' => 'spam',
          'user_agent' => 'Mozilla/5.0'
        )
      end

      it 'disables all email notifications for the recipient' do
        expect_any_instance_of(EmailLog).to receive(:disable_all_email_notifications!)

        perform_job(event_type: 'complaint', payload: { 'Details' => 'test' })
      end

      context 'provider-specific extraction' do
        it 'extracts postmark complaint data' do
          perform_job(
            provider: 'postmark',
            event_type: 'complaint',
            payload: { 'Details' => 'Outlook/16.0' }
          )

          expect(email_log.reload.metadata['user_agent']).to eq('Outlook/16.0')
        end

        it 'extracts sendgrid complaint data' do
          perform_job(
            provider: 'sendgrid',
            event_type: 'complaint',
            payload: { 'useragent' => 'Gmail/1.0' }
          )

          expect(email_log.reload.metadata['user_agent']).to eq('Gmail/1.0')
        end

        it 'extracts mailgun complaint data' do
          perform_job(
            provider: 'mailgun',
            event_type: 'complaint',
            payload: { 'user-agent' => 'Yahoo/1.0' }
          )

          expect(email_log.reload.metadata['user_agent']).to eq('Yahoo/1.0')
        end

        it 'uses fallback for unknown provider' do
          perform_job(
            provider: 'custom',
            event_type: 'complaint',
            payload: { 'user_agent' => 'CustomClient/1.0' }
          )

          expect(email_log.reload.metadata['user_agent']).to eq('CustomClient/1.0')
        end
      end
    end

    # ---------------------------------------------------------------
    # DELIVERY EVENTS
    # ---------------------------------------------------------------
    describe 'delivery events' do
      it 'updates email_log status to delivered' do
        perform_job(
          event_type: 'delivered',
          payload: { 'DeliveredAt' => '2026-03-03T10:00:00Z' }
        )

        expect(email_log.reload.status).to eq('delivered')
      end

      it 'stores delivery metadata' do
        perform_job(
          event_type: 'delivered',
          payload: { 'DeliveredAt' => '2026-03-03T10:00:00Z' }
        )

        expect(email_log.reload.metadata['delivery_time']).to eq('2026-03-03T10:00:00Z')
      end

      context 'provider-specific delivery time extraction' do
        it 'extracts postmark delivery time from DeliveredAt' do
          perform_job(
            provider: 'postmark',
            event_type: 'delivered',
            payload: { 'DeliveredAt' => '2026-03-03T12:00:00Z' }
          )

          expect(email_log.reload.metadata['delivery_time']).to eq('2026-03-03T12:00:00Z')
        end

        it 'extracts sendgrid delivery time from timestamp' do
          perform_job(
            provider: 'sendgrid',
            event_type: 'delivered',
            payload: { 'timestamp' => '1709467200' }
          )

          expect(email_log.reload.metadata['delivery_time']).to eq('1709467200')
        end

        it 'extracts mailgun delivery time from timestamp' do
          perform_job(
            provider: 'mailgun',
            event_type: 'delivery',
            payload: { 'timestamp' => '1709467200' }
          )

          expect(email_log.reload.metadata['delivery_time']).to eq('1709467200')
        end

        it 'uses current time for unknown provider' do
          travel_to(Time.current) do
            perform_job(
              provider: 'custom',
              event_type: 'delivered',
              payload: {}
            )

            expect(email_log.reload.metadata['delivery_time']).to eq(Time.current.iso8601)
          end
        end
      end
    end

    # ---------------------------------------------------------------
    # OPEN EVENTS
    # ---------------------------------------------------------------
    describe 'open events' do
      it 'updates email_log status to opened' do
        perform_job(
          event_type: 'open',
          payload: { 'Geo' => { 'IP' => '1.2.3.4' }, 'UserAgent' => 'Mozilla/5.0' }
        )

        expect(email_log.reload.status).to eq('opened')
      end

      it 'stores open tracking metadata' do
        perform_job(
          event_type: 'open',
          payload: { 'Geo' => { 'IP' => '1.2.3.4' }, 'UserAgent' => 'Mozilla/5.0' }
        )

        email_log.reload
        expect(email_log.metadata).to include(
          'ip_address' => '1.2.3.4',
          'user_agent' => 'Mozilla/5.0'
        )
      end

      context 'when email is already in clicked status' do
        let!(:email_log) do
          ActsAsTenant.with_tenant(organisation) do
            create(:email_log, :clicked,
                   notification: notification,
                   organisation: organisation,
                   provider_message_id: message_id,
                   metadata: { 'provider' => 'postmark' })
          end
        end

        it 'does not downgrade status from clicked to opened' do
          perform_job(
            event_type: 'open',
            payload: { 'Geo' => { 'IP' => '1.2.3.4' }, 'UserAgent' => 'test' }
          )

          expect(email_log.reload.status).to eq('clicked')
        end
      end

      context 'provider-specific extraction' do
        it 'extracts postmark geo data' do
          perform_job(
            provider: 'postmark',
            event_type: 'open',
            payload: {
              'Geo' => { 'IP' => '1.2.3.4', 'City' => 'Berlin', 'Country' => 'DE' },
              'UserAgent' => 'Mozilla/5.0'
            }
          )

          email_log.reload
          expect(email_log.metadata).to include('ip_address' => '1.2.3.4')
        end

        it 'extracts sendgrid open data' do
          perform_job(
            provider: 'sendgrid',
            event_type: 'opened',
            payload: { 'ip' => '5.6.7.8', 'useragent' => 'Chrome/100' }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'ip_address' => '5.6.7.8',
            'user_agent' => 'Chrome/100'
          )
        end

        it 'extracts mailgun open data with geo' do
          perform_job(
            provider: 'mailgun',
            event_type: 'opened',
            payload: {
              'ip' => '9.10.11.12',
              'user-agent' => 'Safari/15',
              'city' => 'Munich',
              'country' => 'DE'
            }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'ip_address' => '9.10.11.12',
            'user_agent' => 'Safari/15'
          )
        end
      end
    end

    # ---------------------------------------------------------------
    # CLICK EVENTS
    # ---------------------------------------------------------------
    describe 'click events' do
      it 'updates email_log status to clicked' do
        perform_job(
          event_type: 'click',
          payload: { 'OriginalLink' => 'https://example.com/ticket/1' }
        )

        expect(email_log.reload.status).to eq('clicked')
      end

      it 'stores click URL in metadata' do
        perform_job(
          event_type: 'click',
          payload: { 'OriginalLink' => 'https://example.com/ticket/1', 'Geo' => { 'IP' => '1.2.3.4' } }
        )

        email_log.reload
        clicks = email_log.metadata['clicks']
        expect(clicks).to be_an(Array)
        expect(clicks.last).to include('url' => 'https://example.com/ticket/1')
      end

      context 'provider-specific click URL extraction' do
        it 'extracts postmark click URL from OriginalLink' do
          perform_job(
            provider: 'postmark',
            event_type: 'click',
            payload: { 'OriginalLink' => 'https://postmark.example.com' }
          )

          clicks = email_log.reload.metadata['clicks']
          expect(clicks.last['url']).to eq('https://postmark.example.com')
        end

        it 'extracts sendgrid click URL from url' do
          perform_job(
            provider: 'sendgrid',
            event_type: 'click',
            payload: { 'url' => 'https://sendgrid.example.com' }
          )

          clicks = email_log.reload.metadata['clicks']
          expect(clicks.last['url']).to eq('https://sendgrid.example.com')
        end

        it 'extracts mailgun click URL from url' do
          perform_job(
            provider: 'mailgun',
            event_type: 'clicked',
            payload: { 'url' => 'https://mailgun.example.com' }
          )

          clicks = email_log.reload.metadata['clicks']
          expect(clicks.last['url']).to eq('https://mailgun.example.com')
        end

        it 'falls back to link key for unknown provider' do
          perform_job(
            provider: 'custom',
            event_type: 'click',
            payload: { 'link' => 'https://custom.example.com' }
          )

          clicks = email_log.reload.metadata['clicks']
          expect(clicks.last['url']).to eq('https://custom.example.com')
        end
      end
    end

    # ---------------------------------------------------------------
    # UNSUBSCRIBE EVENTS
    # ---------------------------------------------------------------
    describe 'unsubscribe events' do
      it 'updates email_log status to unsubscribed' do
        perform_job(event_type: 'unsubscribe')
        expect(email_log.reload.status).to eq('unsubscribed')
      end

      it 'stores unsubscribe metadata with timestamp and method' do
        travel_to(Time.current) do
          perform_job(event_type: 'unsubscribe')

          email_log.reload
          expect(email_log.metadata).to include(
            'unsubscribed_at' => Time.current.iso8601,
            'unsubscribe_method' => 'provider_webhook'
          )
        end
      end

      it 'disables single event email notification for the recipient' do
        expect_any_instance_of(EmailLog).to receive(:disable_single_event_email_notification!)
        perform_job(event_type: 'unsubscribe')
      end

      it 'preserves existing metadata' do
        perform_job(event_type: 'unsubscribe')
        expect(email_log.reload.metadata).to include('provider' => 'postmark')
      end
    end

    # ---------------------------------------------------------------
    # DEFERRED EVENTS
    # ---------------------------------------------------------------
    describe 'deferred events' do
      it 'updates email_log status to deferred' do
        perform_job(
          event_type: 'deferred',
          payload: { 'Description' => 'Server busy' }
        )

        expect(email_log.reload.status).to eq('deferred')
      end

      it 'stores defer reason in metadata' do
        travel_to(Time.current) do
          perform_job(
            event_type: 'deferred',
            payload: { 'Description' => 'Server busy' }
          )

          email_log.reload
          expect(email_log.metadata).to include(
            'deferred_at' => Time.current.iso8601,
            'defer_reason' => 'Server busy'
          )
        end
      end

      it 'preserves existing metadata' do
        perform_job(
          event_type: 'deferred',
          payload: { 'Description' => 'Server busy' }
        )

        expect(email_log.reload.metadata).to include('provider' => 'postmark')
      end

      context 'provider-specific defer reason extraction' do
        it 'extracts postmark defer reason from Description' do
          perform_job(
            provider: 'postmark',
            event_type: 'deferred',
            payload: { 'Description' => 'Mailbox temporarily unavailable' }
          )

          expect(email_log.reload.metadata['defer_reason']).to eq('Mailbox temporarily unavailable')
        end

        it 'extracts sendgrid defer reason from response' do
          perform_job(
            provider: 'sendgrid',
            event_type: 'deferred',
            payload: { 'response' => '421 Try again later' }
          )

          expect(email_log.reload.metadata['defer_reason']).to eq('421 Try again later')
        end

        it 'extracts mailgun defer reason from description' do
          perform_job(
            provider: 'mailgun',
            event_type: 'delayed',
            payload: { 'description' => 'Rate limit exceeded' }
          )

          expect(email_log.reload.metadata['defer_reason']).to eq('Rate limit exceeded')
        end

        it 'uses default reason for unknown provider with empty payload' do
          perform_job(
            provider: 'custom',
            event_type: 'deferred',
            payload: {}
          )

          expect(email_log.reload.metadata['defer_reason']).to eq('Temporary delivery failure')
        end
      end
    end

    # ---------------------------------------------------------------
    # Edge Case: Empty / nil payload values
    # ---------------------------------------------------------------
    describe 'edge cases with payload values' do
      it 'handles bounce with nil payload values gracefully' do
        expect do
          perform_job(
            event_type: 'bounce',
            payload: { 'Type' => nil, 'Description' => nil, 'Details' => nil }
          )
        end.not_to raise_error
      end

      it 'handles empty payload for delivery' do
        expect do
          perform_job(event_type: 'delivered', payload: {})
        end.not_to raise_error

        expect(email_log.reload.status).to eq('delivered')
      end

      it 'handles open with missing Geo data for postmark' do
        expect do
          perform_job(
            provider: 'postmark',
            event_type: 'open',
            payload: { 'UserAgent' => 'test' }
          )
        end.not_to raise_error
      end

      it 'handles click with completely empty payload' do
        expect do
          perform_job(event_type: 'click', payload: {})
        end.not_to raise_error

        expect(email_log.reload.status).to eq('clicked')
      end

      it 'handles deferred with empty payload' do
        expect do
          perform_job(provider: 'custom', event_type: 'deferred', payload: {})
        end.not_to raise_error

        expect(email_log.reload.metadata['defer_reason']).to eq('Temporary delivery failure')
      end
    end

    # ---------------------------------------------------------------
    # Cross-tenant isolation
    # ---------------------------------------------------------------
    describe 'multi-tenant isolation' do
      let!(:other_organisation) { create(:organisation) }
      let(:other_recipient) { create(:user, organisation: other_organisation) }

      let!(:other_email_log) do
        ActsAsTenant.with_tenant(other_organisation) do
          other_notification = create(:notification,
                                      recipient: other_recipient,
                                      organisation: other_organisation,
                                      event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
                                      channel: Notifications::Constants::CHANNEL_EMAIL)
          create(:email_log, :sent,
                 notification: other_notification,
                 organisation: other_organisation,
                 provider_message_id: "other-#{message_id}",
                 metadata: { 'provider' => 'sendgrid' })
        end
      end

      it 'processes webhook for the correct organisation' do
        perform_job(
          event_type: 'delivered',
          payload: { 'DeliveredAt' => Time.current.iso8601 }
        )

        expect(email_log.reload.status).to eq('delivered')
        expect(other_email_log.reload.status).to eq('sent')
      end

      it 'sets correct tenant context for the found email_log' do
        tenant_during_processing = nil

        allow(EmailLog).to receive(:record_delivery!).and_wrap_original do |method, *args|
          tenant_during_processing = ActsAsTenant.current_tenant
          method.call(*args)
        end

        perform_job(event_type: 'delivered', payload: {})
        expect(tenant_during_processing).to eq(organisation)
      end
    end
  end
end
