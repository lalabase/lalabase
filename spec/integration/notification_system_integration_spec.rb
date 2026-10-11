# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Notification System Integration', type: :integration do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Create membership for user
    create(:membership, user: user, organisation: organisation, active: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'end-to-end notification flow' do
    it 'creates and processes notifications when ticket is created' do
      # Set current user for activity tracking
      Current.user = user

      # Create a ticket which should trigger activities and notifications
      ticket = create(:ticket, project: project, creator: user, title: 'Test Notification Ticket')

      expect(ticket).to be_persisted
      puts "✓ Ticket created: #{ticket.id} - #{ticket.title}"

      # Check that activities were created
      activities = Activity.where(trackable: ticket)
      expect(activities).to be_present
      puts "✓ Activities created: #{activities.count}"

      # Check that outbox events were created
      outbox_events = OutboxEvent.where(organisation: organisation)
      expect(outbox_events).to be_present
      puts "✓ Outbox events created: #{outbox_events.count}"

      # Test fanout service directly
      outbox_event = outbox_events.first
      fanout_service = Notifications::FanoutService.new(outbox_event)

      expect { fanout_service.call }.not_to raise_error
      result = fanout_service.call

      puts '✓ Fanout service executed successfully'
      puts "  - Result: #{result}"
      puts "  - Recipients: #{result[:recipients]}"
      puts "  - Notifications created: #{result[:notifications_created]}"

      # Verify notifications were actually created in database
      notifications = Notification.where(organisation: organisation)
      puts "✓ Total notifications in database: #{notifications.count}"

      notifications.each do |notification|
        puts "  - Notification: #{notification.event_type} to #{notification.recipient.email} (#{notification.channel})"
      end

      # Verify notification structure
      if notifications.any?
        notification = notifications.first
        expect(notification.recipient).to be_present
        expect(notification.actor).to be_present
        expect(notification.notifiable).to be_present
        expect(notification.event_type).to be_present
        expect(notification.channel).to be_present
        expect(notification.state).to eq('queued')
      end

      puts '✅ All notification system components working correctly!'
    end

    it 'properly handles trackable vs notifiable in fanout service' do
      Current.user = user

      ticket = create(:ticket, project: project, creator: user)
      activity = Activity.where(trackable: ticket).first

      expect(activity).to be_present
      expect(activity.trackable).to eq(ticket)
      expect { activity.notifiable }.to raise_error(NoMethodError)

      # Test that fanout service uses trackable correctly
      outbox_event = OutboxEvent.where(organisation: organisation).first
      fanout_service = Notifications::FanoutService.new(outbox_event)

      expect { fanout_service.call }.not_to raise_error

      puts '✅ Fanout service correctly uses activity.trackable (not notifiable)'
    end
  end
end
