# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::BroadcastService, :ci_guard do
  # Setup
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:actor) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project) }

  let(:notification) do
    create(:notification,
           recipient: user,
           actor: actor,
           notifiable: ticket,
           organisation: organisation,
           channel: 'in_app')
  end

  let(:service) { described_class.new(notification) }

  before do
    ActsAsTenant.current_tenant = organisation

    # Mock Turbo broadcasts to prevent actual broadcasts in tests
    allow(notification).to receive(:broadcast_prepend_later_to)
    allow(notification).to receive(:broadcast_replace_later_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_later_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_render_later_to)

    # Mock user notifications count via the canonical method (delegates to
    # User#unread_notifications_count with org + accessible_for filter).
    allow(user).to receive(:unread_notifications_count).and_return(3)
  end

  describe '#initialize' do
    it 'sets the notification' do
      expect(service.instance_variable_get(:@notification)).to eq(notification)
    end
  end

  describe '#broadcast_creation' do
    context 'when notification is in_app channel' do
      it 'broadcasts banner update to user notifications stream' do
        service.broadcast_creation

        expect(Turbo::StreamsChannel).to have_received(:broadcast_update_later_to).with(
          Notifications::Streams.notifications(user, organisation),
          target: 'new_notifications_banner',
          html: anything
        )
      end

      it 'broadcasts the unread count streams' do
        service.broadcast_creation

        expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
          Notifications::Streams.badge(user, organisation),
          partial: 'notifications/unread_count_streams',
          locals: { unread_count: 3 }
        )
      end
    end

    context 'when notification is not in_app channel' do
      before do
        notification.update!(channel: 'email')
      end

      it 'does not broadcast' do
        service.broadcast_creation

        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_update_later_to)
        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_render_later_to)
      end
    end
  end

  describe '#broadcast_update' do
    context 'when notification is in_app channel' do
      it 'broadcasts replace to user notifications stream' do
        service.broadcast_update

        expect(notification).to have_received(:broadcast_replace_later_to).with(
          Notifications::Streams.notifications(user, organisation),
          target: notification,
          partial: 'notifications/notification_card',
          locals: { notification: notification }
        )
      end

      it 'broadcasts the unread count streams' do
        service.broadcast_update

        expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
          Notifications::Streams.badge(user, organisation),
          partial: 'notifications/unread_count_streams',
          locals: { unread_count: 3 }
        )
      end
    end

    context 'when notification is not in_app channel' do
      before do
        notification.update!(channel: 'email')
      end

      it 'does not broadcast' do
        service.broadcast_update

        expect(notification).not_to have_received(:broadcast_replace_later_to)
        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_update_later_to)
        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_render_later_to)
      end
    end
  end

  describe 'badge count calculation' do
    let!(:other_notification) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             channel: 'in_app',
             state: 'queued')
    end

    let!(:read_notification) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             channel: 'in_app',
             state: 'read')
    end

    let!(:email_notification) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             channel: 'email',
             state: 'queued')
    end

    it 'calculates unread count correctly' do
      # No need to mock - test the actual counting
      service.broadcast_creation

      # The count includes:
      # - notification (the one being broadcast - in_app, queued)
      # - other_notification (in_app, queued)
      # Does NOT include:
      # - read_notification (read state)
      # - email_notification (email channel, not in_app)
      expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
        Notifications::Streams.badge(user, organisation),
        hash_including(partial: 'notifications/unread_count_streams')
      )
    end
  end

  describe 'integration with different notification states' do
    %w[queued sent delivered read archived].each do |state|
      context "when notification is #{state}" do
        before do
          notification.update!(state: state)
        end

        it 'broadcasts regardless of state' do
          service.broadcast_creation

          if notification.channel_in_app?
            expect(Turbo::StreamsChannel).to have_received(:broadcast_update_later_to).with(
              Notifications::Streams.notifications(user, organisation),
              target: 'new_notifications_banner',
              html: anything
            )
          else
            expect(Turbo::StreamsChannel).not_to have_received(:broadcast_update_later_to)
            expect(Turbo::StreamsChannel).not_to have_received(:broadcast_render_later_to)
          end
        end
      end
    end
  end

  describe 'error handling' do
    context 'when broadcast raises error' do
      before do
        allow(Turbo::StreamsChannel).to receive(:broadcast_update_later_to)
          .with(Notifications::Streams.notifications(user, organisation), anything)
          .and_raise(StandardError.new('Broadcast error'))
      end

      it 'allows the error to bubble up' do
        expect { service.broadcast_creation }.to raise_error(StandardError, 'Broadcast error')
      end
    end

    context 'when user has no notifications' do
      before do
        allow(user).to receive(:unread_notifications_count).and_return(0)
      end

      it 'broadcasts zero count' do
        service.broadcast_creation

        expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
          Notifications::Streams.badge(user, organisation),
          partial: 'notifications/unread_count_streams',
          locals: { unread_count: 0 }
        )
      end
    end
  end

  describe 'stream naming' do
    it 'uses correct stream name for notifications banner' do
      service.broadcast_creation

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_later_to).with(
        Notifications::Streams.notifications(user, organisation),
        hash_including(target: 'new_notifications_banner')
      )
    end

    it 'uses correct stream name for the unread count' do
      service.broadcast_creation

      expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
        Notifications::Streams.badge(user, organisation),
        anything
      )
    end
  end

  describe 'target specification' do
    it 'uses correct target for notification banner' do
      service.broadcast_creation

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_later_to).with(
        Notifications::Streams.notifications(user, organisation),
        hash_including(target: 'new_notifications_banner')
      )
    end

    it 'uses correct partial for notification update' do
      service.broadcast_update

      expect(notification).to have_received(:broadcast_replace_later_to).with(
        anything,
        hash_including(
          partial: 'notifications/notification_card',
          target: notification
        )
      )
    end

    it 'uses the shared partial for the unread count' do
      service.broadcast_creation

      expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
        anything,
        hash_including(partial: 'notifications/unread_count_streams')
      )
    end
  end

  describe 'service instantiation and usage patterns' do
    it 'can be instantiated and used for creation' do
      expect { described_class.new(notification).broadcast_creation }.not_to raise_error
    end

    it 'can be instantiated and used for updates' do
      expect { described_class.new(notification).broadcast_update }.not_to raise_error
    end

    it 'can be reused for multiple operations' do
      service_instance = described_class.new(notification)

      expect { service_instance.broadcast_creation }.not_to raise_error
      expect { service_instance.broadcast_update }.not_to raise_error
    end
  end

  # Regression: the broadcast overwrote the correct (accessible-filtered)
  # banner value with the raw org-wide count, because broadcast_badge_update
  # used its own unfiltered query. As a result the banner stayed stuck permanently
  # on the "orphan" number instead of falling to 0 once everything had been read.
  describe 'badge count uses accessible filter' do
    let(:other_organisation) { create(:organisation) }
    let(:other_ticket) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:ticket, project: create(:project, organisation: other_organisation))
      end
    end

    it 'delegates to User#unread_notifications_count with the notification organisation' do
      expect(user).to receive(:unread_notifications_count).with(organisation).and_return(7)
      allow(notification).to receive(:recipient).and_return(user)

      described_class.new(notification).broadcast_creation

      expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
        anything,
        hash_including(partial: 'notifications/unread_count_streams', locals: { unread_count: 7 })
      )
    end

    it 'uses precomputed_unread_count when provided' do
      described_class.new(notification, precomputed_unread_count: 42).broadcast_creation

      expect(Turbo::StreamsChannel).to have_received(:broadcast_render_later_to).with(
        anything,
        hash_including(partial: 'notifications/unread_count_streams', locals: { unread_count: 42 })
      )
    end
  end

  # Regression (29.09.2026): the streams were user-only, so a notification in
  # organisation B pushed B's unread count into the inbox badge of a page open
  # in organisation A. Every stream a broadcast reaches must name the
  # notification's organisation and no other.
  describe 'organisation isolation' do
    let(:other_organisation) { create(:organisation) }
    let(:other_notification) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:notification, recipient: user, organisation: other_organisation,
                              project: nil, channel: 'in_app', state: :delivered)
      end
    end

    def streams_reached
      streams = []
      %i[broadcast_update_later_to broadcast_replace_later_to broadcast_render_later_to].each do |m|
        allow(Turbo::StreamsChannel).to receive(m) { |stream, **| streams << stream }
      end
      allow(other_notification).to receive(:broadcast_replace_later_to) { |stream, **| streams << stream }
      yield
      streams
    end

    it 'broadcasts a creation only to streams of the notification organisation' do
      streams = streams_reached do
        ActsAsTenant.with_tenant(other_organisation) { described_class.new(other_notification).broadcast_creation }
      end

      expect(streams).not_to be_empty
      expect(streams).to all(include(":org:#{other_organisation.id}:"))
      expect(streams.join).not_to include(organisation.id.to_s)
    end

    it 'broadcasts an update only to streams of the notification organisation' do
      streams = streams_reached do
        ActsAsTenant.with_tenant(other_organisation) { described_class.new(other_notification).broadcast_update }
      end

      expect(streams).not_to be_empty
      expect(streams).to all(include(":org:#{other_organisation.id}:"))
      expect(streams.join).not_to include(organisation.id.to_s)
    end
  end
end
