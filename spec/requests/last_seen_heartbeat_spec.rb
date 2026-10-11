# frozen_string_literal: true

require 'rails_helper'

# Presence heartbeat wiring (ApplicationController#touch_last_seen).
#
# Exercised through /session/touch: a plain authenticated GET that skips the
# tenant redirect chain, so it isolates the before_action that records presence.
# Covers the three branches of the guard: fresh session writes, throttled repeat
# does nothing, and is_ai accounts never get a presence timestamp.
RSpec.describe 'last_seen heartbeat', type: :request do
  describe 'GET /session/touch' do
    it 'records last_seen_at for a signed-in user' do
      user = create(:user)
      sign_in user

      get session_touch_path

      expect(response).to have_http_status(:ok)
      expect(user.reload.last_seen_at).to be_within(5.seconds).of(Time.current)
    end

    it 'does not re-write while the previous heartbeat is still fresh (throttle)' do
      user = create(:user)
      fresh = 30.seconds.ago
      user.update_columns(last_seen_at: fresh)
      sign_in user

      expect { get session_touch_path }.not_to(change { user.reload.last_seen_at })
    end

    it 'never records presence for an is_ai account' do
      ai_user = create(:user, is_ai: true)
      sign_in ai_user

      get session_touch_path

      expect(ai_user.reload.last_seen_at).to be_nil
    end
  end
end
