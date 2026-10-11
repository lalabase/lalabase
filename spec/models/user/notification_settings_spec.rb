# frozen_string_literal: true

require 'rails_helper'

# Specs for User::NotificationSettings — the per-user ticket notification
# toggles extracted from the User god-class (user.rb split, slice 4/7).
#
# WHAT THIS GUARDS
# The toggles live in the JSONB slot preferences['ticket_notifications'] and
# decide what "watching a ticket" actually delivers. The slice is a pure
# refactoring, so behaviour must stay bit-identical to the legacy User methods
# it replaced — most examples here are CHARACTERIZATION tests: they pin
# existing behaviour, not new requirements. Read them as "this is what the app
# already does and must keep doing", not "this is a new feature".
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO (mutation-resistance)
# This file is written so that a plausible one-line code change (a "mutant")
# makes a specific example fail. That is the reason behind patterns that can
# look redundant at first glance:
#   - hardcoded predicate/toggle and event-type tables, deliberately NOT
#     iterated from the production constants — otherwise shrinking a constant
#     would silently delete a case instead of reddening a test;
#   - the cross-mapping block disables exactly ONE toggle at a time — a swapped
#     event_type -> toggle mapping cannot hide behind an all-off setup;
#   - a same-key conflict update plus a full-payload reload round-trip — these
#     catch a reversed merge or a boolean-to-string coercion in the JSONB write
#     that the simpler "saves settings" example would pass.
# Each non-obvious example states, in its own comment, which mutant it kills.
#
# LOAD-BEARING CONTRACT: the delegation facade
# ticket_notification_enabled_for? and ticket_auto_follow_created? stay callable
# ON THE USER (via delegate) on purpose. They run in the notification delivery
# hot path (Notifications::FanoutService inside Solid Queue jobs) and in an
# after_create_commit callback, where a regression surfaces asynchronously in a
# job rather than in a request spec. The "delegation facade on User" block
# exists to fail loudly and synchronously the moment a delegate is dropped.
RSpec.describe User::NotificationSettings, type: :model do
  let(:user) { create(:user, preferences: {}) }
  let(:settings) { user.notification_settings }

  describe 'memoization' do
    # Same invariant as the other split slices: the PORO shares the lifetime
    # of the per-instance caches — without `||=` every access would build a
    # fresh instance.
    it 'returns the same instance for the same user instance' do
      expect(user.notification_settings).to equal(user.notification_settings)
    end
  end

  describe 'delegation facade on User' do
    # Load-bearing contract of this slice: FanoutService (Solid Queue job
    # context) and the seven auto-follow call sites keep calling these
    # methods ON THE USER. Both toggle states are compared facade vs PORO so
    # a dropped delegate line fails here, not asynchronously in a job.
    it 'delegates ticket_auto_follow_created? to the PORO (both states)' do
      expect(user.ticket_auto_follow_created?).to be true
      expect(user.ticket_auto_follow_created?)
        .to eq(user.notification_settings.ticket_auto_follow_created?)

      user.notification_settings.update('auto_follow_created' => false)

      expect(user.ticket_auto_follow_created?).to be false
      expect(user.ticket_auto_follow_created?)
        .to eq(user.notification_settings.ticket_auto_follow_created?)
    end

    it 'delegates ticket_notification_enabled_for? to the PORO (both states)' do
      expect(user.ticket_notification_enabled_for?('ticket_commented')).to be true
      expect(user.ticket_notification_enabled_for?('ticket_commented'))
        .to eq(user.notification_settings.ticket_notification_enabled_for?('ticket_commented'))

      user.notification_settings.update('on_comment' => false)

      expect(user.ticket_notification_enabled_for?('ticket_commented')).to be false
      expect(user.ticket_notification_enabled_for?('ticket_commented'))
        .to eq(user.notification_settings.ticket_notification_enabled_for?('ticket_commented'))
    end
  end

  # Baseline contract: a user who never configured anything must still receive
  # every ticket notification (the migration's explicit promise — "all toggles
  # default to true so existing users keep getting all notifications"). Pins the
  # default-true behaviour when the whole slot is absent.
  describe 'default values (no preferences set)' do
    it 'defaults on_status_change to true' do
      expect(settings.ticket_notify_on_status_change?).to be true
    end

    it 'defaults on_priority_change to true' do
      expect(settings.ticket_notify_on_priority_change?).to be true
    end

    it 'defaults on_comment to true' do
      expect(settings.ticket_notify_on_comment?).to be true
    end

    it 'defaults auto_follow_created to true' do
      expect(settings.ticket_auto_follow_created?).to be true
    end
  end

  describe 'default-true semantics (!= false) per predicate' do
    # Hardcoded predicate/toggle list on purpose — iterating a production
    # constant would let a shrinking mutant silently remove examples.
    [
      [:ticket_notify_on_status_change?,   'on_status_change'],
      [:ticket_notify_on_priority_change?, 'on_priority_change'],
      [:ticket_notify_on_comment?,         'on_comment'],
      [:ticket_auto_follow_created?,       'auto_follow_created']
    ].each do |predicate, toggle_key|
      describe "##{predicate}" do
        it 'is true when the toggle is explicitly nil' do
          user.update!(preferences: { 'ticket_notifications' => { toggle_key => nil } })
          expect(settings.public_send(predicate)).to be true
        end

        it 'is false when the toggle is explicitly false' do
          user.update!(preferences: { 'ticket_notifications' => { toggle_key => false } })
          expect(settings.public_send(predicate)).to be false
        end

        it 'is true when the toggle is explicitly true' do
          user.update!(preferences: { 'ticket_notifications' => { toggle_key => true } })
          expect(settings.public_send(predicate)).to be true
        end

        it "is true for a truthy non-boolean value (only false disables, not the string 'false')" do
          user.update!(preferences: { 'ticket_notifications' => { toggle_key => 'false' } })
          expect(settings.public_send(predicate)).to be true
        end
      end
    end
  end

  # Counterpart to the default block: once values are explicitly stored, they
  # must be honoured verbatim (a stored false stays false, a stored true stays
  # true). Pins the read path against a mutant that ignores stored values and
  # always returns the default.
  describe 'reading explicit settings' do
    before do
      user.update!(preferences: {
                     'ticket_notifications' => {
                       'on_status_change' => false,
                       'on_priority_change' => true,
                       'on_comment' => false,
                       'auto_follow_created' => false
                     }
                   })
    end

    it 'reads on_status_change as false' do
      expect(settings.ticket_notify_on_status_change?).to be false
    end

    it 'reads on_priority_change as true' do
      expect(settings.ticket_notify_on_priority_change?).to be true
    end

    it 'reads on_comment as false' do
      expect(settings.ticket_notify_on_comment?).to be false
    end

    it 'reads auto_follow_created as false' do
      expect(settings.ticket_auto_follow_created?).to be false
    end
  end

  # The single write path, driven by notifications_controller#update_preferences.
  # Guards three concerns at once: merge semantics (in-slot siblings AND foreign
  # preference slots survive; same-key conflicts resolve new-value-wins),
  # persistence semantics (save! raises on an invalid user, nothing leaks), and
  # the realistic JSONB round-trip (the full four-toggle controller payload
  # survives a reload as proper booleans).
  describe '#update' do
    it 'saves settings to preferences JSONB' do
      settings.update(
        'on_status_change' => false,
        'on_comment' => false
      )
      user.reload

      expect(settings.ticket_notify_on_status_change?).to be false
      expect(settings.ticket_notify_on_comment?).to be false
      # Unset keys default to true
      expect(settings.ticket_notify_on_priority_change?).to be true
      expect(settings.ticket_auto_follow_created?).to be true
    end

    it 'merges with existing settings (in-slot siblings survive)' do
      settings.update('on_status_change' => false)
      settings.update('on_comment' => false)
      user.reload

      expect(settings.ticket_notify_on_status_change?).to be false
      expect(settings.ticket_notify_on_comment?).to be false
    end

    it 'round-trips the full controller payload (all four toggles, mixed booleans) through reload' do
      # The real write path (notifications_controller#update_preferences) always
      # sends all four toggles at once with mixed true/false. Pins the realistic
      # JSONB shape: each value persists as a boolean and deserializes back
      # correctly after a DB round-trip — in particular auto_follow_created in
      # the false state, which only ever reaches the DB through this path and is
      # otherwise asserted only in-memory (facade spec, no reload).
      settings.update(
        'on_status_change' => false,
        'on_priority_change' => true,
        'on_comment' => false,
        'auto_follow_created' => false
      )
      user.reload

      expect(user.preferences['ticket_notifications']).to eq(
        'on_status_change' => false,
        'on_priority_change' => true,
        'on_comment' => false,
        'auto_follow_created' => false
      )
      expect(settings.ticket_notify_on_status_change?).to be false
      expect(settings.ticket_notify_on_priority_change?).to be true
      expect(settings.ticket_notify_on_comment?).to be false
      expect(settings.ticket_auto_follow_created?).to be false
    end

    it 'lets a later update overwrite the SAME key (new value wins on conflict)' do
      # The sibling-merge test above only sets disjoint keys, so it survives a
      # reversed merge (settings.merge(current)). This pins the conflict
      # direction: the newly written value must win, not the stored one —
      # otherwise toggling a setting OFF and back ON would silently no-op.
      settings.update('on_comment' => true)
      settings.update('on_comment' => false)
      user.reload

      expect(settings.ticket_notify_on_comment?).to be false
      expect(user.preferences['ticket_notifications']['on_comment']).to be false
    end

    it 'preserves other preferences keys' do
      user.update!(preferences: { 'some_other_key' => 'value' })
      settings.update('on_status_change' => false)
      user.reload

      expect(user.preferences['some_other_key']).to eq('value')
      expect(settings.ticket_notify_on_status_change?).to be false
    end

    it 'leaves foreign preference slots untouched (sibling coexistence)' do
      # Realistic neighbors from the other split slices: a nested slot
      # (sidebar_colors, slice 3) and a flat scalar (items_per_page, slice 1).
      user.update!(preferences: {
                     'sidebar_colors' => { 'some-org-id' => '#112233' },
                     'items_per_page' => 50
                   })

      settings.update('on_comment' => false)
      user.reload

      expect(user.preferences['sidebar_colors']).to eq('some-org-id' => '#112233')
      expect(user.preferences['items_per_page']).to eq(50)
      expect(settings.ticket_notify_on_comment?).to be false
    end

    it 'returns true on success' do
      expect(settings.update('on_comment' => false)).to be true
    end

    it 'raises and persists nothing when the user is invalid (save! semantics)' do
      user.email = ''

      expect do
        settings.update('on_comment' => false)
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(user.reload.preferences['ticket_notifications']).to be_nil
    end
  end

  # The event-type -> toggle dispatch that FanoutService calls per recipient.
  # Two failure modes are separated on purpose: mapping correctness (does each
  # event type consult the RIGHT toggle) lives in the cross-mapping context;
  # gating correctness (does a disabled toggle actually suppress) lives in the
  # all-disabled context. Untracked event types (assignments, mentions, system)
  # must always pass — that is the else branch.
  describe '#ticket_notification_enabled_for?' do
    context 'when all settings are true (default)' do
      it 'returns true for ticket_status_changed' do
        expect(settings.ticket_notification_enabled_for?('ticket_status_changed')).to be true
      end

      it 'returns true for ticket_blocker (priority)' do
        expect(settings.ticket_notification_enabled_for?('ticket_blocker')).to be true
      end

      it 'returns true for ticket_commented' do
        expect(settings.ticket_notification_enabled_for?('ticket_commented')).to be true
      end

      it 'returns true for ticket_assigned (always enabled)' do
        expect(settings.ticket_notification_enabled_for?('ticket_assigned')).to be true
      end

      it 'returns true for mention (always enabled)' do
        expect(settings.ticket_notification_enabled_for?('mention')).to be true
      end
    end

    context 'cross mapping (exactly one toggle disabled at a time)' do
      # Pins WHICH toggle controls WHICH event type. The all-disabled context
      # below cannot catch a swapped mapping — these isolation examples do.
      # Hardcoded table, deliberately not derived from the case statement.
      it "maps 'ticket_status_changed' to on_status_change only" do
        settings.update('on_status_change' => false)

        expect(settings.ticket_notification_enabled_for?('ticket_status_changed')).to be false
        expect(settings.ticket_notification_enabled_for?('ticket_blocker')).to be true
        expect(settings.ticket_notification_enabled_for?('ticket_commented')).to be true
      end

      it "maps 'ticket_blocker' to on_priority_change only (NOT on_comment)" do
        settings.update('on_priority_change' => false)

        expect(settings.ticket_notification_enabled_for?('ticket_blocker')).to be false
        expect(settings.ticket_notification_enabled_for?('ticket_status_changed')).to be true
        expect(settings.ticket_notification_enabled_for?('ticket_commented')).to be true
      end

      it "maps 'ticket_commented' to on_comment only" do
        settings.update('on_comment' => false)

        expect(settings.ticket_notification_enabled_for?('ticket_commented')).to be false
        expect(settings.ticket_notification_enabled_for?('ticket_status_changed')).to be true
        expect(settings.ticket_notification_enabled_for?('ticket_blocker')).to be true
      end
    end

    context 'when specific settings are disabled' do
      before do
        settings.update(
          'on_status_change' => false,
          'on_priority_change' => false,
          'on_comment' => false
        )
      end

      it 'returns false for ticket_status_changed' do
        expect(settings.ticket_notification_enabled_for?('ticket_status_changed')).to be false
      end

      it 'returns false for ticket_blocker (priority)' do
        expect(settings.ticket_notification_enabled_for?('ticket_blocker')).to be false
      end

      it 'returns false for ticket_commented' do
        expect(settings.ticket_notification_enabled_for?('ticket_commented')).to be false
      end

      # Else branch: event types WITHOUT a toggle stay on even when every
      # existing toggle is disabled. Hardcoded list of representatives.
      %w[ticket_assigned ticket_unassigned mention system_message].each do |event_type|
        it "still returns true for #{event_type} (always enabled)" do
          expect(settings.ticket_notification_enabled_for?(event_type)).to be true
        end
      end
    end
  end
end
