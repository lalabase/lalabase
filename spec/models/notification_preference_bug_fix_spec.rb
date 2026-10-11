# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'NotificationPreference Bug Fix - ticket_status_changed', type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, active: true)
  end

  describe 'Full-Matrix Preference Creation (Bug Fix)' do
    it 'creates disabled preferences for all unchecked combinations' do
      # Simulate the full-matrix approach from the controller
      all_event_types = NotificationPreference.event_types.keys
      all_channels = NotificationPreference.channels.keys

      # Simulate empty params (all unchecked)
      preference_params = {}

      # Prosopite pause: the test deliberately simulates the naive loop approach (not production code)
      Prosopite.pause

      # Iterate over all combinations as in the controller
      all_event_types.each do |event_type|
        all_channels.each do |channel|
          settings = preference_params.dig(event_type, channel) || {}

          # Checkbox logic: only enabled when explicitly '1' or 'true'
          enabled = settings['enabled'].in?(%w[1 true])
          frequency = enabled ? 'immediate' : 'never'

          preference = user.notification_preferences
                           .find_or_initialize_by(
                             event_type: event_type,
                             channel: channel,
                             organisation: organisation
                           )

          preference.assign_attributes(
            enabled: enabled,
            frequency: frequency
          )

          preference.save! if preference.new_record? || preference.changed?
        end
      end

      Prosopite.resume

      # Assertions: one preference per (event_type × channel), all disabled (empty params).
      # Derive the count from the SAME source the loop iterates — hardcoding it (was 18 =
      # 9×2) silently broke when M9 added the index_completed/index_failed event types.
      created_preferences = NotificationPreference.where(user: user, organisation: organisation)
      expected_count = all_event_types.size * all_channels.size
      expect(created_preferences.count).to eq(expected_count)
      expect(created_preferences.where(enabled: false).count).to eq(expected_count) # all disabled
      expect(created_preferences.where(enabled: true).count).to eq(0) # none enabled
    end

    it 'respects explicit enabled settings' do
      # Simulate params with some enabled preferences
      preference_params = {
        'ticket_status_changed' => {
          'in_app' => { 'enabled' => '0' }, # Explicitly disabled
          'email' => { 'enabled' => '1' } # Explicitly enabled
        },
        'mention' => {
          'in_app' => { 'enabled' => '1' } # Explicitly enabled
        }
      }

      # Iterate over all combinations
      all_event_types = NotificationPreference.event_types.keys
      all_channels = NotificationPreference.channels.keys

      # Prosopite pause: the test deliberately simulates the naive loop approach (not production code)
      Prosopite.pause

      all_event_types.each do |event_type|
        all_channels.each do |channel|
          settings = preference_params.dig(event_type, channel) || {}

          enabled = settings['enabled'].in?(%w[1 true])
          frequency = enabled ? 'immediate' : 'never'

          preference = user.notification_preferences
                           .find_or_initialize_by(
                             event_type: event_type,
                             channel: channel,
                             organisation: organisation
                           )

          preference.assign_attributes(
            enabled: enabled,
            frequency: frequency
          )

          preference.save! if preference.new_record? || preference.changed?
        end
      end

      Prosopite.resume

      # Check specific preferences
      status_in_app = NotificationPreference.find_by(
        user: user, event_type: 'ticket_status_changed', channel: 'in_app'
      )
      status_email = NotificationPreference.find_by(
        user: user, event_type: 'ticket_status_changed', channel: 'email'
      )
      mention_in_app = NotificationPreference.find_by(
        user: user, event_type: 'mention', channel: 'in_app'
      )

      expect(status_in_app.enabled?).to be false
      expect(status_email.enabled?).to be true
      expect(status_email.frequency).to eq('immediate')
      expect(mention_in_app.enabled?).to be true
    end
  end

  describe 'Suppression with disabled preferences' do
    it 'suppresses notifications when preference is disabled' do
      # Create disabled preference for ticket_status_changed
      NotificationPreference.create!(
        user: user,
        organisation: organisation,
        event_type: 'ticket_status_changed',
        channel: 'in_app',
        enabled: false,
        frequency: 'never'
      )

      # Create activity for status change
      activity = create(:activity,
                        trackable: ticket,
                        key: 'ticket.status_changed',
                        organisation: organisation,
                        actor: create(:user)) # different user as actor

      # Test suppression
      suppressor = Notifications::Suppressor.new(activity, user, 50, 'in_app')

      # Mock event_type mapping
      allow(suppressor).to receive(:derive_event_type).and_return('ticket_status_changed')

      # Expect suppression
      expect(suppressor.send(:suppress_muted?)).to be true
      expect(suppressor.suppression_reasons).to include(:muted_preference)
    end

    it 'allows notifications when preference is enabled' do
      # Create enabled preference for ticket_status_changed
      NotificationPreference.create!(
        user: user,
        organisation: organisation,
        event_type: 'ticket_status_changed',
        channel: 'in_app',
        enabled: true,
        frequency: 'immediate'
      )

      # Create activity for status change
      activity = create(:activity,
                        trackable: ticket,
                        key: 'ticket.status_changed',
                        organisation: organisation,
                        actor: create(:user)) # different user as actor

      # Test suppression
      suppressor = Notifications::Suppressor.new(activity, user, 50, 'in_app')

      # Mock event_type mapping
      allow(suppressor).to receive(:derive_event_type).and_return('ticket_status_changed')

      # Expect NO suppression due to preferences (may still be suppressed for other reasons)
      expect(suppressor.send(:suppress_muted?)).to be false
    end
  end

  describe 'Regression: resolve_for with defaults vs. persisted' do
    it 'returns persisted disabled preference instead of enabled default' do
      # Create explicitly disabled preference
      disabled_pref = NotificationPreference.create!(
        user: user,
        organisation: organisation,
        event_type: 'ticket_status_changed',
        channel: 'in_app',
        enabled: false,
        frequency: 'never'
      )

      # resolve_for should return the persisted preference
      resolved = NotificationPreference.resolve_for(
        user: user,
        event_type: 'ticket_status_changed',
        channel: 'in_app',
        scope: ticket
      )

      expect(resolved).to be_persisted
      expect(resolved).to eq(disabled_pref)
      expect(resolved.enabled?).to be false
    end

    it 'creates default when no preference exists' do
      # No preference exists
      expect(NotificationPreference.where(
               user: user,
               event_type: 'ticket_status_changed',
               channel: 'in_app'
             )).to be_empty

      # resolve_for should create a default (not persisted)
      resolved = NotificationPreference.resolve_for(
        user: user,
        event_type: 'ticket_status_changed',
        channel: 'in_app',
        scope: ticket
      )

      expect(resolved).not_to be_persisted
      expect(resolved.enabled?).to be true # default is enabled
      expect(resolved.frequency).to eq('immediate') # Simplified: always immediate
    end
  end
end
