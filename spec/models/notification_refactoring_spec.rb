# frozen_string_literal: true

require 'rails_helper'

# Regression test to verify the notification refactoring is working correctly
RSpec.describe Notification, type: :model do
  let(:organisation) { create(:organisation) }
  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, organisation: organisation)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'refactoring verification' do
    it 'does not respond to removed view methods' do
      expect(notification).not_to respond_to(:title)
      expect(notification).not_to respond_to(:message)
      expect(notification).not_to respond_to(:icon)
      expect(notification).not_to respond_to(:action_url)
      expect(notification).not_to respond_to(:css_class)
    end

    it 'does not have broadcasting callbacks' do
      create_callbacks = Notification._create_callbacks.select { |cb| cb.filter.to_s.include?('broadcast') }
      update_callbacks = Notification._update_callbacks.select { |cb| cb.filter.to_s.include?('broadcast') }

      expect(create_callbacks).to be_empty
      expect(update_callbacks).to be_empty
    end

    it 'still has core functionality' do
      expect(notification).to respond_to(:mark_as_read!)
      expect(notification).to respond_to(:unread?)
      expect(notification).to respond_to(:grouped?)
      expect(notification).to respond_to(:high_priority?)
      expect(notification).to respond_to(:should_send_immediately?)
    end

    it 'has correct associations' do
      expect(notification).to respond_to(:recipient)
      expect(notification).to respond_to(:actor)
      expect(notification).to respond_to(:notifiable)
      expect(notification).to respond_to(:organisation)
      expect(notification).to respond_to(:project)
      expect(notification).to respond_to(:email_logs)
    end

    it 'has correct enums' do
      expect(Notification.states.keys).to include('queued', 'sent', 'delivered', 'read', 'archived')
      expect(Notification.channels.keys).to include('in_app', 'email')
      expect(Notification.priorities.keys).to include('low', 'normal', 'high', 'critical')
    end

    it 'includes constants module' do
      expect(Notification.ancestors).to include(Notifications::Constants)
    end
  end

  describe 'state management' do
    let(:queued_notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, organisation: organisation, state: 'queued')
      end
    end

    it 'can mark as read' do
      expect do
        queued_notification.mark_as_read!
      end.to change { queued_notification.state }.to('read')
                                                 .and change { queued_notification.read_at }.from(nil).to(be_within(1.second).of(Time.current))
    end

    it 'can archive' do
      expect do
        queued_notification.archive!
      end.to change { queued_notification.state }.to('archived')
                                                 .and change { queued_notification.archived_at }.from(nil).to(be_within(1.second).of(Time.current))
    end
  end

  describe 'business logic methods' do
    it 'correctly identifies unread notifications' do
      ActsAsTenant.with_tenant(organisation) do
        unread_notification = create(:notification, organisation: organisation, state: 'queued')
        read_notification = create(:notification, organisation: organisation, state: 'read')

        expect(unread_notification.unread?).to be true
        expect(read_notification.unread?).to be false
      end
    end

    it 'correctly identifies grouped notifications' do
      ActsAsTenant.with_tenant(organisation) do
        grouped_notification = create(:notification, organisation: organisation, group_count: 3)
        single_notification = create(:notification, organisation: organisation, group_count: 1)

        expect(grouped_notification.grouped?).to be true
        expect(single_notification.grouped?).to be false
      end
    end

    it 'correctly identifies high priority notifications' do
      ActsAsTenant.with_tenant(organisation) do
        high_priority_notification = create(:notification, organisation: organisation, priority: 'high')
        normal_notification = create(:notification, organisation: organisation, priority: 'normal')

        expect(high_priority_notification.high_priority?).to be true
        expect(normal_notification.high_priority?).to be false
      end
    end
  end
end
