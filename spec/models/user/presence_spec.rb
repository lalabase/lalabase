# frozen_string_literal: true

require 'rails_helper'

# Presence heartbeat contract (User::Presence).
#
# These specs pin the three behaviours the "last seen" feature relies on:
#   1. #mark_seen! writes at most once per SEEN_THROTTLE (write coalescing),
#   2. #mark_seen! is a pure heartbeat — it must NOT bump updated_at or fire the
#      Trackable -> Activity side-effect chain (it goes through update_all),
#   3. #online? / #stale_last_seen? classify a timestamp against the windows.
#
# Timestamps are set explicitly (no time travel) so the throttle/window
# boundaries are asserted directly.
RSpec.describe User::Presence, type: :model do
  let(:user) { create(:user) }

  describe '#stale_last_seen?' do
    it 'is true when never seen (nil)' do
      expect(user.last_seen_at).to be_nil
      expect(user.stale_last_seen?).to be(true)
    end

    it 'is true once the last write is older than the throttle' do
      user.update_columns(last_seen_at: (User::Presence::SEEN_THROTTLE + 1.minute).ago)
      expect(user.stale_last_seen?).to be(true)
    end

    it 'is false while the last write is still within the throttle' do
      user.update_columns(last_seen_at: 30.seconds.ago)
      expect(user.stale_last_seen?).to be(false)
    end
  end

  describe '#mark_seen!' do
    it 'records the timestamp when the user was never seen before' do
      user.mark_seen!
      expect(user.reload.last_seen_at).to be_within(5.seconds).of(Time.current)
    end

    it 'refreshes the timestamp once the previous write is stale' do
      user.update_columns(last_seen_at: 10.minutes.ago)
      user.mark_seen!
      expect(user.reload.last_seen_at).to be_within(5.seconds).of(Time.current)
    end

    it 'coalesces: does not write again while the last write is fresh' do
      fresh = 30.seconds.ago
      user.update_columns(last_seen_at: fresh)

      expect { user.mark_seen! }.not_to(change { user.reload.last_seen_at })
    end

    it 'does not bump updated_at (no callbacks, no side-effect chain)' do
      user.update_columns(updated_at: 1.hour.ago)
      before = user.reload.updated_at

      user.mark_seen!

      expect(user.reload.updated_at).to be_within(1.second).of(before)
    end

    it 'does not create an Activity audit record' do
      # Activity is acts_as_tenant; count outside any tenant scope to prove the
      # heartbeat wrote nothing to the audit trail.
      expect { user.mark_seen! }
        .not_to(change { ActsAsTenant.without_tenant { Activity.count } })
    end
  end

  describe '#online?' do
    it 'is false when never seen' do
      expect(user.online?).to be(false)
    end

    it 'is true within the online window' do
      user.update_columns(last_seen_at: (User::Presence::ONLINE_WINDOW - 1.minute).ago)
      expect(user.online?).to be(true)
    end

    it 'is false once past the online window' do
      user.update_columns(last_seen_at: (User::Presence::ONLINE_WINDOW + 1.minute).ago)
      expect(user.online?).to be(false)
    end
  end
end
