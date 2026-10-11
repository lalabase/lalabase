# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SessionTouch', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  describe 'GET /session/touch' do
    context 'when not authenticated' do
      it 'returns 401' do
        get session_touch_path, headers: { 'Accept' => 'application/json' }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated' do
      before { sign_in user }

      it 'returns expires_at and timeout_minutes' do
        get session_touch_path, headers: { 'Accept' => 'application/json' }
        expect(response).to have_http_status(:success)
        body = response.parsed_body
        expect(body['timeout_minutes']).to eq(user.session_timeout_minutes)
        expect(Time.parse(body['expires_at'])).to be_within(2.seconds).of(Time.current + user.timeout_in)
      end

      it 'reflects the per-user timeout setting' do
        user.update!(session_timeout_minutes: 480)
        get session_touch_path, headers: { 'Accept' => 'application/json' }
        expect(response.parsed_body['timeout_minutes']).to eq(480)
        expect(Time.parse(response.parsed_body['expires_at'])).to be_within(2.seconds).of(Time.current + 480.minutes)
      end

      it 'checks the actual deadline without extending an idle session or presence' do
        get session_touch_path, headers: { 'Accept' => 'application/json' }
        expires_at = response.parsed_body.fetch('expires_at')
        last_seen_at = user.reload.last_seen_at

        travel 10.minutes do
          get session_touch_path(check: 1), headers: { 'Accept' => 'application/json' }
          expect(response.parsed_body.fetch('expires_at')).to eq(expires_at)
          expect(user.reload.last_seen_at).to eq(last_seen_at)
        end

        travel user.timeout_in + 1.second do
          get session_touch_path(check: 1), headers: { 'Accept' => 'application/json' }
          expect(response).to have_http_status(:unauthorized)
          expect(response.headers['Cache-Control']).to include('no-cache')
        end
      end

      it 'returns the account and a fresh CSRF token for resuming an open form' do
        get session_touch_path(check: 1), headers: { 'Accept' => 'application/json' }
        expect(response.parsed_body['user_id']).to eq(user.id)
        expect(response.parsed_body['csrf_token']).to be_present
        expect(response.headers['Cache-Control']).to include('no-store')
      end
    end
  end
end
