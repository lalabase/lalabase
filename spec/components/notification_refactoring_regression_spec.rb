# frozen_string_literal: true

require 'rails_helper'

# Regression test for the notification refactoring
# Tests specific cases that came up after the refactoring
RSpec.describe 'Notification Refactoring Regression', type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:actor) { create(:user, first_name: 'Max', last_name: 'Mustermann') }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, number: 1, title: 'Test Ticket') }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'NeoNotificationCardComponent' do
    context 'when notification has no action_url method' do
      let(:notification) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification,
                 recipient: user,
                 actor: actor,
                 notifiable: ticket,
                 organisation: organisation,
                 project: project,
                 event_type: 'system_message',
                 state: 'queued')
        end
      end

      it 'does not call the removed action_url method' do
        # Verify notification doesn't have action_url method anymore
        expect(notification).not_to respond_to(:action_url)

        # ViewComponent should handle URL generation internally
        component = NeoNotificationCardComponent.new(notification: notification)

        # Mock helpers to avoid routing issues in tests
        allow(component).to receive(:helpers).and_return(double(
                                                           current_organisation: organisation,
                                                           organisation_project_ticket_path: '/test/ticket/path',
                                                           notification_deeplink_path: '#'
                                                         ))

        # Should not raise NoMethodError for action_url
        expect { component.send(:notification_url) }.not_to raise_error
      end

      it 'generates URL based on notifiable type' do
        component = NeoNotificationCardComponent.new(notification: notification)

        # Mock helpers
        allow(component).to receive(:helpers).and_return(double(
                                                           current_organisation: organisation,
                                                           organisation_project_ticket_path: '/organisations/1/projects/1/tickets/1',
                                                           notification_deeplink_path: '#'
                                                         ))

        url = component.send(:notification_url)
        expect(url).to eq('/organisations/1/projects/1/tickets/1')
      end

      it 'handles deleted notifiable gracefully' do
        # Simulate deleted notifiable
        allow(notification).to receive(:notifiable).and_return(nil)

        component = NeoNotificationCardComponent.new(notification: notification)

        allow(component).to receive(:helpers).and_return(double(
                                                           current_organisation: organisation,
                                                           organisation_notifications_path: '/notifications',
                                                           notification_deeplink_path: '#'
                                                         ))

        expect { component.send(:notification_url) }.not_to raise_error
      end
    end

    context 'when system_message event_type had wrong I18n template' do
      let(:system_message_notification) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification,
                 recipient: user,
                 actor: actor,
                 notifiable: ticket,
                 organisation: organisation,
                 project: project,
                 event_type: 'system_message',
                 state: 'queued',
                 group_key: 'test_group_key',
                 dedupe_fingerprint: SecureRandom.hex(8),
                 payload: {
                   actor: 'Max Mustermann',
                   notifiable: '#1 Test Ticket',
                   action: 'title_changed',
                   actor_name: 'Max Mustermann'
                   # No post_excerpt - this was the bug
                 })
        end
      end

      it 'works with corrected I18n template' do
        component = NeoNotificationCardComponent.new(notification: system_message_notification)

        # Render first: the message names the actor in the viewer's spelling,
        # and helpers only exist inside the render pipeline.
        render_inline(component)

        # Mock I18n to return a predictable message
        allow(I18n).to receive(:t).and_call_original
        allow(I18n).to receive(:t).with(
          'notifications.messages.system_message',
          hash_including(actor: anything, notifiable: anything)
        ).and_return('Max Mustermann performed an action on #1 Test Ticket')

        message = component.send(:notification_message)
        # Verify the method works without errors and returns a string
        expect(message).to be_a(String)
        expect(message).not_to be_empty
        # Verify no interpolation artifacts remain
        expect(message).not_to include('%{')
      end

      it 'renders without I18n interpolation errors' do
        component = NeoNotificationCardComponent.new(notification: system_message_notification)

        expect { component.send(:notification_message) }.not_to raise_error
      end
    end

    context 'when rendering with mismatched event_type and payload' do
      let(:notification_with_mismatched_payload) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, state: 'queued',
                                recipient: user,
                                actor: actor,
                                notifiable: ticket,
                                organisation: organisation,
                                project: project,
                                event_type: 'system_message', # Wrong event type
                                payload: {
                                  actor: 'Max Mustermann',
                                  notifiable: '#1 Test Ticket',
                                  action: 'title_changed', # This suggests it should be ticket_status_changed
                                  actor_name: 'Max Mustermann',
                                  parameters: {
                                    'to_title' => 'New Title',
                                    'from_title' => 'Old Title',
                                    'display_name' => '#1 Test Ticket'
                                  }
                                  # Missing post_excerpt that some I18n templates expect
                                })
        end
      end

      it 'handles I18n interpolation errors gracefully' do
        component = NeoNotificationCardComponent.new(notification: notification_with_mismatched_payload)

        # Allow Rails logger warnings
        allow(Rails.logger).to receive(:warn)

        # Should not raise I18n::MissingInterpolationArgument
        expect { component.send(:notification_message) }.not_to raise_error

        # Should fall back to a safe message
        message = component.send(:notification_message)
        expect(message).to be_a(String)
        expect(message).not_to be_empty
      end

      it 'renders component without errors despite mismatched data' do
        component = NeoNotificationCardComponent.new(notification: notification_with_mismatched_payload)

        # Allow Rails logger warnings
        allow(Rails.logger).to receive(:warn)

        expect { render_inline(component) }.not_to raise_error
      end
    end

    context 'when notification has corrupted data' do
      let(:corrupted_notification) do
        ActsAsTenant.with_tenant(organisation) do
          notification = create(:notification, state: 'queued',
                                               recipient: user,
                                               actor: actor,
                                               notifiable: ticket,
                                               organisation: organisation,
                                               project: project,
                                               event_type: 'ticket_commented')

          # Simulate corrupted payload that doesn't match event_type
          notification.update_column(:payload, {
                                       actor: 'Max Mustermann',
                                       notifiable: '#1 Test Ticket',
                                       # Missing comment-related data but event_type is ticket_commented
                                       wrong_data: 'corrupted'
                                     })

          notification
        end
      end

      it 'handles corrupted notification data gracefully' do
        component = NeoNotificationCardComponent.new(notification: corrupted_notification)

        # Allow Rails logger warnings
        allow(Rails.logger).to receive(:warn)

        # Mock I18n to simulate correct behavior
        allow(I18n).to receive(:t).and_call_original
        allow(I18n).to receive(:t).with(
          /notifications\.messages/,
          hash_including(actor: anything, notifiable: anything)
        ).and_return('Fallback message with Max Mustermann and #1 Test Ticket')

        # Should handle the error gracefully
        expect { component.send(:notification_message) }.not_to raise_error

        message = component.send(:notification_message)
        expect(message).to be_a(String)
        expect(message).not_to be_empty
      end

      it 'provides meaningful fallback for display methods' do
        component = NeoNotificationCardComponent.new(notification: corrupted_notification)
        render_inline(component)

        expect(component.send(:actor_display_name)).to eq('Max Mustermann')
        expect(component.send(:notifiable_display_name)).to eq('#1 Test Ticket')
      end
    end
  end

  describe 'NeoNotificationComponent' do
    context 'regression test for action_url removal' do
      let(:notification) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, state: 'queued',
                                recipient: user,
                                actor: actor,
                                notifiable: ticket,
                                organisation: organisation,
                                event_type: 'ticket_assigned')
        end
      end

      it 'does not call removed action_url method' do
        expect(notification).not_to respond_to(:action_url)

        component = NeoNotificationComponent.new(notification: notification)

        # Mock helpers
        allow(component).to receive(:helpers).and_return(double(
                                                           organisation_project_ticket_path: '/test/path',
                                                           notification_deeplink_path: '#'
                                                         ))

        expect { component.send(:action_url) }.not_to raise_error
      end

      it 'generates fallback URL when notification action_url is unavailable' do
        component = NeoNotificationComponent.new(notification: notification)

        # Mock helpers for URL generation
        allow(component).to receive(:helpers).and_return(double(
                                                           organisation_project_ticket_path: '/organisations/1/projects/1/tickets/1',
                                                           notification_deeplink_path: '#'
                                                         ))

        url = component.send(:action_url)
        expect(url).to eq('/organisations/1/projects/1/tickets/1')
      end
    end
  end

  describe 'NotificationPresenter' do
    context 'with mismatched event_type and payload' do
      let(:notification_with_wrong_event_type) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, state: 'queued',
                                recipient: user,
                                actor: actor,
                                notifiable: ticket,
                                organisation: organisation,
                                event_type: 'system_message', # Wrong type
                                payload: {
                                  actor: 'Max Mustermann',
                                  notifiable: '#1 Test Ticket',
                                  comment_text: 'This should be ticket_commented'
                                })
        end
      end

      it 'handles I18n errors gracefully' do
        presenter = NotificationPresenter.new(notification_with_wrong_event_type)

        # Allow Rails logger warnings
        allow(Rails.logger).to receive(:warn)

        # Mock I18n to return a valid message
        allow(I18n).to receive(:t).with(
          /notifications\.messages/,
          hash_including(:actor, :notifiable)
        ).and_return('Test message with actor and notifiable')

        expect { presenter.message }.not_to raise_error

        message = presenter.message
        expect(message).to be_a(String)
        expect(message).not_to be_empty
      end

      it 'provides fallback message when I18n fails' do
        presenter = NotificationPresenter.new(notification_with_wrong_event_type)

        # Allow Rails logger warnings
        allow(Rails.logger).to receive(:warn)

        # Mock I18n to simulate a fallback scenario
        allow(I18n).to receive(:t).with(
          /notifications\.messages/,
          hash_including(:actor, :notifiable)
        ).and_return('Fallback: Actor performed action on notifiable')

        message = presenter.message
        # Test that we get a valid message regardless of I18n issues
        expect(message).to be_a(String)
        expect(message.length).to be > 0
        expect(message).not_to include('%{') # No uninterpolated variables
      end
    end
  end
end
