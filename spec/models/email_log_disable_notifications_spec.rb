# frozen_string_literal: true

require 'rails_helper'
require 'support/email_log_test_helper'

RSpec.describe EmailLog, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             event_type: 'ticket_assigned',
             channel: 'email')
    end
  end
  let(:email_log) do
    ActsAsTenant.with_tenant(organisation) do
      create(:email_log,
             notification: notification,
             organisation: organisation,
             status: 'bounced',
             provider_message_id: SecureRandom.uuid)
    end
  end

  describe '#disable_all_email_notifications!' do
    it 'creates a disabled preference for every valid event type' do
      with_tenant(organisation) do
        expect do
          email_log.disable_all_email_notifications!
        end.to change(NotificationPreference, :count).by(Notifications::Constants::VALID_EVENT_TYPES.size)

        # Pause Prosopite for assertion loop — verification queries are not N+1
        Prosopite.pause
        Notifications::Constants::VALID_EVENT_TYPES.each do |event_type|
          pref = NotificationPreference.find_by(
            user: user,
            organisation_id: nil,
            scope_type: nil,
            scope_id: nil,
            event_type: event_type,
            channel: 'email'
          )
          expect(pref).to be_present, "Expected preference for #{event_type}"
          expect(pref.enabled).to be false
          expect(pref.frequency).to eq('never')
        end
        Prosopite.resume
      end
    end

    it 'is idempotent — second call creates no duplicates' do
      with_tenant(organisation) do
        email_log.disable_all_email_notifications!

        expect do
          email_log.disable_all_email_notifications!
        end.not_to change(NotificationPreference, :count)

        # Pause Prosopite for assertion loop — verification queries are not N+1
        Prosopite.pause
        Notifications::Constants::VALID_EVENT_TYPES.each do |event_type|
          pref = NotificationPreference.find_by(
            user: user,
            event_type: event_type,
            channel: 'email',
            organisation_id: nil
          )
          expect(pref.enabled).to be false
        end
        Prosopite.resume
      end
    end

    it 'creates global preferences without organisation_id' do
      with_tenant(organisation) do
        email_log.disable_all_email_notifications!

        prefs = NotificationPreference.where(user: user, channel: 'email')
        prefs.each do |pref|
          expect(pref.organisation_id).to be_nil
          expect(pref.scope_type).to be_nil
          expect(pref.scope_id).to be_nil
        end
      end
    end
  end

  describe '#disable_single_event_email_notification!' do
    it 'creates only one preference record for the notification event type' do
      with_tenant(organisation) do
        expect do
          email_log.disable_single_event_email_notification!
        end.to change(NotificationPreference, :count).by(1)

        pref = NotificationPreference.find_by(
          user: user,
          event_type: 'ticket_assigned',
          channel: 'email',
          organisation_id: nil
        )
        expect(pref).to be_present
        expect(pref.enabled).to be false
        expect(pref.frequency).to eq('never')
      end
    end

    it 'does not affect other event types' do
      with_tenant(organisation) do
        email_log.disable_single_event_email_notification!

        other_types = Notifications::Constants::VALID_EVENT_TYPES - ['ticket_assigned']
        other_prefs = NotificationPreference.where(
          user: user,
          event_type: other_types,
          channel: 'email',
          organisation_id: nil
        )
        expect(other_prefs).to be_empty
      end
    end
  end

  describe 'integration: record_bounce! with Permanent bounce' do
    it 'disables all 9 event types' do
      with_tenant(organisation) do
        EmailLog.record_bounce!(
          email_log.provider_message_id,
          { type: 'Permanent', reason: 'Mailbox not found', diagnostic_code: '550' }
        )

        Prosopite.pause
        Notifications::Constants::VALID_EVENT_TYPES.each do |event_type|
          pref = NotificationPreference.find_by(
            user: user,
            event_type: event_type,
            channel: 'email',
            organisation_id: nil
          )
          expect(pref).to be_present, "Expected disabled preference for #{event_type}"
          expect(pref.enabled).to be false
        end
        Prosopite.resume
      end
    end

    it 'does not disable for Temporary bounces' do
      with_tenant(organisation) do
        EmailLog.record_bounce!(
          email_log.provider_message_id,
          { type: 'Temporary', reason: 'Mailbox full', diagnostic_code: '452' }
        )

        prefs = NotificationPreference.where(user: user, channel: 'email', enabled: false)
        expect(prefs.count).to eq(0)
      end
    end
  end

  describe 'integration: record_complaint!' do
    it 'disables all 9 event types' do
      with_tenant(organisation) do
        EmailLog.record_complaint!(
          email_log.provider_message_id,
          { type: 'spam', user_agent: 'TestAgent' }
        )

        disabled_count = NotificationPreference.where(
          user: user,
          channel: 'email',
          enabled: false,
          organisation_id: nil
        ).count

        expect(disabled_count).to eq(Notifications::Constants::VALID_EVENT_TYPES.size)
      end
    end
  end

  describe 'integration: check_and_disable_notifications after 3+ failures' do
    it 'disables all event types when failure threshold is reached' do
      with_tenant(organisation) do
        # Pause Prosopite during factory setup — independent record creation is not N+1
        Prosopite.pause
        # Create 2 additional failed email logs for the same recipient
        2.times do
          other_notification = create(:notification,
                                      recipient: user,
                                      organisation: organisation,
                                      event_type: 'ticket_commented',
                                      channel: 'email')
          create(:email_log,
                 notification: other_notification,
                 organisation: organisation,
                 status: 'failed')
        end

        # The third failure (our email_log) is already bounced.
        # Trigger handle_status_change by updating status to bounced again
        # (simulating a fresh bounce).
        fresh_notification = create(:notification,
                                    recipient: user,
                                    organisation: organisation,
                                    event_type: 'ticket_assigned',
                                    channel: 'email')
        fresh_log = create(:email_log,
                           notification: fresh_notification,
                           organisation: organisation,
                           status: 'sent',
                           provider_message_id: SecureRandom.uuid)
        Prosopite.resume

        # Update to bounced triggers handle_status_change → check_and_disable_notifications
        fresh_log.update!(status: 'bounced')

        disabled_count = NotificationPreference.where(
          user: user,
          channel: 'email',
          enabled: false,
          organisation_id: nil
        ).count

        expect(disabled_count).to eq(Notifications::Constants::VALID_EVENT_TYPES.size)
      end
    end
  end
end
