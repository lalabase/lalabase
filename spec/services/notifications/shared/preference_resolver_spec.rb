# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::Shared::PreferenceResolver do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, active: true) unless user.organisations.include?(organisation)
  end

  around do |example|
    ActsAsTenant.with_tenant(organisation) do
      example.run
    end
  end

  describe '#initialize' do
    it 'stores user and organisation' do
      resolver = described_class.new(user, organisation)
      expect(resolver.user).to eq(user)
      expect(resolver.organisation).to eq(organisation)
    end

    it 'falls back to user first organisation when none provided' do
      resolver = described_class.new(user)
      expect(resolver.organisation).to eq(user.organisations.first)
    end

    it 'handles user with no organisations gracefully' do
      lonely_user = create(:user)
      resolver = described_class.new(lonely_user)
      expect(resolver.organisation).to be_nil
    end
  end

  describe '#resolve' do
    let(:resolver) { described_class.new(user, organisation) }

    context 'without existing preferences (system default)' do
      it 'returns a NotificationPreference' do
        result = resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be_a(NotificationPreference)
      end

      it 'returns a default preference that is enabled with immediate frequency' do
        result = resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result.enabled?).to be true
        expect(result.frequency_immediate?).to be true
      end

      it 'returns an unsaved default (not persisted)' do
        result = resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result.new_record?).to be true
      end
    end

    context 'with existing user preference' do
      let!(:preference) do
        create(:notification_preference,
               user: user,
               organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: false,
               frequency: 'never')
      end

      it 'returns the stored preference' do
        result = resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result.id).to eq(preference.id)
        expect(result.enabled?).to be false
        expect(result.frequency_never?).to be true
      end
    end

    context 'caching behavior' do
      it 'caches results for identical parameters' do
        expect(NotificationPreference).to receive(:resolve_for).once.and_call_original

        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
      end

      it 'does NOT cache across different event types' do
        expect(NotificationPreference).to receive(:resolve_for).twice.and_call_original

        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_MENTION,
          channel: :in_app
        )
      end

      it 'does NOT cache across different channels' do
        expect(NotificationPreference).to receive(:resolve_for).twice.and_call_original

        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :email
        )
      end

      it 'does NOT cache across different scopes' do
        other_ticket = create(:ticket, project: project, organisation: organisation, creator: user)

        expect(NotificationPreference).to receive(:resolve_for).twice.and_call_original

        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app,
          scope: ticket
        )
        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app,
          scope: other_ticket
        )
      end

      it 'distinguishes nil scope from object scope' do
        expect(NotificationPreference).to receive(:resolve_for).twice.and_call_original

        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app,
          scope: nil
        )
        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app,
          scope: ticket
        )
      end
    end

    context 'with scope (hierarchical resolution)' do
      it 'passes scope to resolve_for' do
        expect(NotificationPreference).to receive(:resolve_for).with(
          user: user,
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app,
          scope: ticket
        ).and_call_original

        resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app,
          scope: ticket
        )
      end
    end
  end

  describe '#batch_resolve' do
    let(:resolver) { described_class.new(user, organisation) }
    let(:other_user) { create(:user) }

    let!(:notifications) do
      [
        create(:notification, :ticket_commented,
               recipient: user, organisation: organisation, actor: other_user,
               notifiable: ticket),
        create(:notification, :ticket_assigned,
               recipient: user, organisation: organisation, actor: other_user,
               notifiable: ticket)
      ]
    end

    context 'happy path' do
      it 'returns a hash keyed by notification id' do
        result = resolver.batch_resolve(notifications, channel: :in_app)

        expect(result).to be_a(Hash)
        expect(result.keys).to contain_exactly(*notifications.map(&:id))
      end

      it 'resolves preferences for each notification' do
        result = resolver.batch_resolve(notifications, channel: :in_app)

        result.each_value do |pref|
          expect(pref).to be_a(NotificationPreference)
        end
      end
    end

    context 'with empty notifications' do
      it 'returns empty hash' do
        result = resolver.batch_resolve([], channel: :email)
        expect(result).to eq({})
      end

      it 'does not call resolve_for' do
        expect(NotificationPreference).not_to receive(:resolve_for)
        resolver.batch_resolve([])
      end
    end

    context 'with pre-cached items' do
      before do
        # Pre-warm the cache for the first notification's event type
        resolver.resolve(
          event_type: notifications.first.event_type,
          channel: :in_app,
          scope: notifications.first.notifiable
        )
      end

      it 'does not call resolve_for again for cached notifications' do
        # Only the second notification (different event_type) should trigger a resolve
        expect(NotificationPreference).to receive(:resolve_for).at_most(:once).and_call_original

        resolver.batch_resolve(notifications, channel: :in_app)
      end
    end

    context 'with duplicate event types across notifications' do
      let!(:same_type_notifications) do
        2.times.map do
          create(:notification, :ticket_commented,
                 recipient: user, organisation: organisation, actor: other_user,
                 notifiable: ticket)
        end
      end

      it 'resolves once for identical cache keys' do
        # Both notifications have same event_type + channel + notifiable → same cache key
        result = resolver.batch_resolve(same_type_notifications, channel: :in_app)

        # Both notifications should get the same preference (same cache key)
        prefs = result.values.compact
        expect(prefs.map(&:event_type).uniq.size).to eq(1)
        expect(result.size).to eq(2)
      end
    end

    context 'default channel' do
      it 'defaults to :email channel' do
        result = resolver.batch_resolve(notifications)

        # batch_resolve defaults to :email channel — verify cached key includes email
        expect(result).not_to be_empty
        stats = resolver.cache_stats
        expect(stats[:keys].first).to include(':email:')
      end
    end
  end

  describe '#should_send_immediately?' do
    let(:resolver) { described_class.new(user, organisation) }

    context 'when preference is enabled with immediate frequency' do
      before do
        create(:notification_preference,
               user: user, organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: true, frequency: 'immediate')
      end

      it 'returns true' do
        result = resolver.should_send_immediately?(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be true
      end
    end

    context 'when preference is disabled' do
      before do
        create(:notification_preference,
               user: user, organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: false, frequency: 'immediate')
      end

      it 'returns false' do
        result = resolver.should_send_immediately?(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be false
      end
    end

    context 'when frequency is never (even if enabled)' do
      before do
        create(:notification_preference,
               user: user, organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: true, frequency: 'never')
      end

      it 'returns false' do
        result = resolver.should_send_immediately?(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be false
      end
    end

    context 'when no preference exists (uses default)' do
      it 'returns true (default is enabled + immediate)' do
        result = resolver.should_send_immediately?(
          event_type: Notifications::Constants::EVENT_TYPE_MENTION,
          channel: :in_app
        )
        expect(result).to be true
      end
    end
  end

  describe '#should_suppress?' do
    let(:resolver) { described_class.new(user, organisation) }

    context 'when preference is enabled with immediate frequency' do
      before do
        create(:notification_preference,
               user: user, organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: true, frequency: 'immediate')
      end

      it 'returns false' do
        result = resolver.should_suppress?(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be false
      end
    end

    context 'when preference is disabled' do
      before do
        create(:notification_preference,
               user: user, organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: false, frequency: 'immediate')
      end

      it 'returns true' do
        result = resolver.should_suppress?(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be true
      end
    end

    context 'when frequency is never' do
      before do
        create(:notification_preference,
               user: user, organisation: organisation,
               event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
               channel: 'in_app',
               enabled: true, frequency: 'never')
      end

      it 'returns true' do
        result = resolver.should_suppress?(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        expect(result).to be true
      end
    end

    it 'is the exact logical negation of should_send_immediately?' do
      # Verifies the code smell: these two methods are always inverse
      event_type = Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED
      channel = :in_app

      send = resolver.should_send_immediately?(event_type: event_type, channel: channel)
      suppress = resolver.should_suppress?(event_type: event_type, channel: channel)

      expect(send).to eq(!suppress)
    end
  end

  describe '#clear_cache!' do
    let(:resolver) { described_class.new(user, organisation) }

    it 'empties the cache' do
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
        channel: :in_app
      )
      expect(resolver.cache_stats[:size]).to eq(1)

      resolver.clear_cache!
      expect(resolver.cache_stats[:size]).to eq(0)
    end

    it 'forces fresh resolution on next resolve call' do
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
        channel: :in_app
      )

      resolver.clear_cache!

      # Should call resolve_for again after cache clear
      expect(NotificationPreference).to receive(:resolve_for).once.and_call_original
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
        channel: :in_app
      )
    end
  end

  describe '#cache_stats' do
    let(:resolver) { described_class.new(user, organisation) }

    it 'returns empty stats initially' do
      stats = resolver.cache_stats
      expect(stats[:size]).to eq(0)
      expect(stats[:keys]).to be_empty
    end

    it 'tracks cache entries' do
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
        channel: :in_app
      )
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_MENTION,
        channel: :email
      )

      stats = resolver.cache_stats
      expect(stats[:size]).to eq(2)
      expect(stats[:keys].size).to eq(2)
    end
  end

  describe 'cache key structure' do
    let(:resolver) { described_class.new(user, organisation) }

    it 'builds deterministic keys including user, org, event_type, channel, scope' do
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
        channel: :in_app,
        scope: ticket
      )

      key = resolver.cache_stats[:keys].first
      expect(key).to include(user.id)
      expect(key).to include(organisation.id)
      expect(key).to include('ticket_commented')
      expect(key).to include('in_app')
      expect(key).to include(ticket.id)
    end

    it 'uses "nil" string for nil scope' do
      resolver.resolve(
        event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
        channel: :in_app,
        scope: nil
      )

      key = resolver.cache_stats[:keys].first
      expect(key).to end_with(':nil')
    end
  end

  describe 'edge cases' do
    context 'when organisation is nil' do
      let(:resolver) { described_class.new(user, nil) }

      it 'falls back to user.organisations.first' do
        expect(resolver.organisation).to eq(user.organisations.first)
      end
    end

    context 'resolve_for raises an error' do
      let(:resolver) { described_class.new(user, organisation) }

      before do
        allow(NotificationPreference).to receive(:resolve_for).and_raise(StandardError, 'DB error')
      end

      it 'propagates the error (no silent swallowing)' do
        expect do
          resolver.resolve(
            event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
            channel: :in_app
          )
        end.to raise_error(StandardError, 'DB error')
      end
    end

    context 'batch_resolve when resolve_for fails for one item' do
      let(:resolver) { described_class.new(user, organisation) }
      let(:other_user) { create(:user) }

      let!(:notifications) do
        [
          create(:notification, :ticket_commented,
                 recipient: user, organisation: organisation, actor: other_user,
                 notifiable: ticket)
        ]
      end

      before do
        # batch_resolve uses a direct where query instead of resolve_for
        allow(NotificationPreference).to receive(:where).and_raise(StandardError, 'DB error')
      end

      it 'propagates the error' do
        expect do
          resolver.batch_resolve(notifications, channel: :in_app)
        end.to raise_error(StandardError, 'DB error')
      end
    end

    context 'caching with nil resolve result' do
      let(:resolver) { described_class.new(user, organisation) }

      it 'caches nil results (key?-based caching handles nil correctly)' do
        allow(NotificationPreference).to receive(:resolve_for).and_return(nil, 'second_call')

        first = resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )
        second = resolver.resolve(
          event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
          channel: :in_app
        )

        # key?-based caching correctly caches nil — resolve_for called only once
        expect(first).to be_nil
        expect(second).to be_nil
        expect(NotificationPreference).to have_received(:resolve_for).once
      end
    end
  end

  describe 'code smell: should_send_immediately? and should_suppress? are always inverse' do
    let(:resolver) { described_class.new(user, organisation) }

    Notifications::Constants::VALID_EVENT_TYPES.each do |event_type|
      %i[in_app email].each do |channel|
        it "#{event_type}/#{channel}: should_send_immediately? == !should_suppress?" do
          send = resolver.should_send_immediately?(event_type: event_type, channel: channel)
          suppress = resolver.should_suppress?(event_type: event_type, channel: channel)

          expect(send).to eq(!suppress),
                          "Expected inverse for #{event_type}/#{channel}: send=#{send}, suppress=#{suppress}"
        end
      end
    end
  end
end
