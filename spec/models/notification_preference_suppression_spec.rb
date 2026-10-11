# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'NotificationPreference Suppression Matrix', type: :model do
  include ActiveSupport::Testing::TimeHelpers
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:activity) { ActsAsTenant.with_tenant(organisation) { create(:activity, trackable: ticket, organisation: organisation) } }

  before do
    # Set tenant and ensure user is member of organisation
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, active: true)
  end

  # Test matrix: Implemented event types × 3 channels
  # NOTE: mention commented out because @-detection is not yet implemented
  EVENTS = %w[
    ticket_commented ticket_assigned ticket_unassigned
    ticket_status_changed ticket_blocker
    project_announcement document_added system_message
  ].freeze

  CHANNELS = %w[in_app email].freeze

  describe 'Preference Resolution and Suppression' do
    context 'when preference is explicitly disabled' do
      EVENTS.each do |event_type|
        CHANNELS.each do |channel|
          it "suppresses #{event_type} on #{channel} when disabled" do
            # Create an explicitly disabled preference
            preference = NotificationPreference.create!(
              user: user,
              organisation: organisation,
              event_type: event_type,
              channel: channel,
              enabled: false,
              frequency: 'never'
            )

            # Resolve should return the disabled preference
            resolved = NotificationPreference.resolve_for(
              user: user,
              event_type: event_type,
              channel: channel,
              scope: ticket
            )

            expect(resolved).to be_persisted
            expect(resolved.enabled?).to be false
            expect(resolved).to eq(preference)

            # Suppressor should suppress when in_app is disabled
            if channel == 'in_app'
              suppressor = Notifications::Suppressor.new(activity, user, 50, channel)
              # Mock event_type mapping
              allow(suppressor).to receive(:derive_event_type).and_return(event_type)

              # Expect suppression for disabled preferences
              expect(suppressor.send(:suppress_muted?)).to be true
              expect(suppressor.suppression_reasons).to include(:muted_preference)
            end
          end
        end
      end
    end

    context 'when no preference exists' do
      EVENTS.each do |event_type|
        CHANNELS.each do |channel|
          it "creates default for #{event_type} on #{channel}" do
            # No preference exists
            expect(NotificationPreference.where(
                     user: user,
                     event_type: event_type,
                     channel: channel
                   )).to be_empty

            # Resolve should create a default (not persisted)
            resolved = NotificationPreference.resolve_for(
              user: user,
              event_type: event_type,
              channel: channel,
              scope: ticket
            )

            expect(resolved).not_to be_persisted
            expect(resolved.enabled?).to be true # Defaults are enabled (for backwards compatibility)

            # Simplified: default frequency is always 'immediate'
            expect(resolved.frequency).to eq('immediate')
          end
        end
      end
    end

    context 'preference hierarchy' do
      it 'respects preference hierarchy: item > project > org > global' do
        event_type = 'ticket_commented'
        channel = 'email'

        # Global preference (lowest priority)
        global_pref = NotificationPreference.create!(
          user: user,
          event_type: event_type,
          channel: channel,
          enabled: true,
          frequency: 'immediate'
        )

        # Organisation preference (higher priority)
        org_pref = NotificationPreference.create!(
          user: user,
          organisation: organisation,
          event_type: event_type,
          channel: channel,
          enabled: true,
          frequency: 'immediate'
        )

        # Project preference (even higher priority)
        project_pref = NotificationPreference.create!(
          user: user,
          scope_type: 'Project',
          scope_id: project.id,
          event_type: event_type,
          channel: channel,
          enabled: false,
          frequency: 'never'
        )

        # Item preference (highest priority)
        ticket_pref = NotificationPreference.create!(
          user: user,
          scope_type: 'Ticket',
          scope_id: ticket.id,
          event_type: event_type,
          channel: channel,
          enabled: true,
          frequency: 'immediate'
        )

        # Test resolution
        resolved = NotificationPreference.resolve_for(
          user: user,
          event_type: event_type,
          channel: channel,
          scope: ticket
        )

        # Should return item-level preference
        expect(resolved).to eq(ticket_pref)
        expect(resolved.enabled?).to be true
        expect(resolved.frequency).to eq('immediate')

        # Delete item preference, should fall back to project
        ticket_pref.destroy
        resolved = NotificationPreference.resolve_for(
          user: user,
          event_type: event_type,
          channel: channel,
          scope: ticket
        )

        expect(resolved).to eq(project_pref)
        expect(resolved.enabled?).to be false

        # Delete project preference, should fall back to org
        project_pref.destroy
        resolved = NotificationPreference.resolve_for(
          user: user,
          event_type: event_type,
          channel: channel,
          scope: ticket
        )

        expect(resolved).to eq(org_pref)
        expect(resolved.frequency).to eq('immediate')

        # Delete org preference, should fall back to global
        org_pref.destroy
        resolved = NotificationPreference.resolve_for(
          user: user,
          event_type: event_type,
          channel: channel,
          scope: ticket
        )

        expect(resolved).to eq(global_pref)
        expect(resolved.frequency).to eq('immediate')
      end
    end
  end

  describe 'Special Cases' do
    context 'frequency: never' do
      it 'suppresses notifications even when enabled is true' do
        preference = NotificationPreference.create!(
          user: user,
          organisation: organisation,
          event_type: 'ticket_commented',
          channel: 'email',
          enabled: true,
          frequency: 'never'
        )

        expect(preference.should_deliver_now?).to be false
      end

      it 'suppresses in_app notifications via Suppressor when frequency=never' do
        # CRITICAL TEST: frequency='never' should suppress in_app notifications
        NotificationPreference.create!(
          user: user,
          organisation: organisation,
          event_type: 'ticket_commented',
          channel: 'in_app',
          enabled: true, # enabled but frequency='never'
          frequency: 'never'
        )

        # Suppressor should suppress even when enabled=true
        suppressor = Notifications::Suppressor.new(activity, user, 50, 'in_app')
        allow(suppressor).to receive(:derive_event_type).and_return('ticket_commented')

        expect(suppressor.send(:suppress_muted?)).to be true
        expect(suppressor.suppression_reasons).to include(:frequency_never)
      end
    end

    context 'system_message special handling' do
      it 'always uses immediate for in_app system messages' do
        resolved = NotificationPreference.resolve_for(
          user: user,
          event_type: 'system_message',
          channel: 'in_app',
          scope: nil
        )

        expect(resolved.frequency).to eq('immediate')
      end
    end
  end

  describe 'Regression Guards' do
    it 'does not create duplicate preferences for same combination' do
      attrs = {
        user: user,
        organisation: organisation,
        event_type: 'ticket_commented',
        channel: 'email'
      }

      NotificationPreference.create!(attrs.merge(enabled: true))

      expect do
        NotificationPreference.create!(attrs.merge(enabled: false))
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'validates event_type is in allowed list' do
      # Enum validation
      expect do
        NotificationPreference.create!(
          user: user,
          event_type: 'invalid_event',
          channel: 'email',
          enabled: true
        )
      end.to raise_error(ArgumentError)
    end

    it 'validates channel is in allowed list' do
      # Enum validation
      expect do
        NotificationPreference.create!(
          user: user,
          event_type: 'mention',
          channel: 'invalid_channel',
          enabled: true
        )
      end.to raise_error(ArgumentError)
    end
  end
end
