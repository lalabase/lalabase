# frozen_string_literal: true

require 'rails_helper'

# What: DELETE /api/v1/app_session, the sign-out of a client. It revokes the token the
#   request came with, whatever its kind, and no other.
# Why: the token of a device reaches the whole account and may write. Signing out must
#   end exactly that token, at once, and must not be a way to end anybody else's.
#   Every refusal below has its success in the same block.
RSpec.describe 'App sign-out (DELETE /api/v1/app_session)', :ci_guard, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:path) { '/api/v1/app_session' }
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, email: 'person@example.com') }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation),
                          active: true)
    end
  end

  # A token with its plaintext, as the door or the token page hands it out.
  def issue(*traits, owner: user, **attributes)
    token = build(:personal_access_token, *traits, user: owner, **attributes)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  let(:device) { issue(:app_session, name: 'iPhone') }
  let(:personal) { issue(organisations: [organisation], read_only: false, name: 'Terminal') }
  let(:read_only) { issue(organisations: [organisation], read_only: true, name: 'Leser') }

  def bearer(token, extra = {})
    { 'Authorization' => "Bearer #{token.token}" }.merge(extra)
  end

  def sign_out(token, headers: {})
    delete path, headers: bearer(token, headers)
  end

  def json
    response.parsed_body
  end

  def expect_signed_out(token)
    expect(response).to have_http_status(:ok)
    expect(json.keys).to eq(['data'])
    expect(json['data'].keys).to eq(['revoked_at'])
    expect(token.reload).to be_revoked
    expect(json.dig('data', 'revoked_at')).to eq(token.revoked_at.iso8601)
  end

  describe 'a sign-out' do
    it 'revokes the token of the request, a device token and a personal one, and answers when' do
      freeze_time do
        sign_out(device)
        expect_signed_out(device)
        expect(json.dig('data', 'revoked_at')).to eq(Time.current.iso8601)

        sign_out(personal)
        expect_signed_out(personal)
      end
    end

    it 'ends the token at once: the next call with it gets 401, a second sign-out as well' do
      get '/api/v1/me', headers: bearer(device)
      expect(response).to have_http_status(:ok)

      sign_out(device)
      expect_signed_out(device)
      revoked_at = device.revoked_at

      get '/api/v1/me', headers: bearer(device)
      expect(response).to have_http_status(:unauthorized)

      sign_out(device)
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq('error' => 'unauthorized', 'code' => 'unauthorized')
      expect(device.reload.revoked_at).to eq(revoked_at)
    end

    it 'leaves every other token alone: of the same account and of another one' do
      other_device = issue(:app_session, name: 'iPad')
      stranger = create(:user, email: 'person2@example.com')
      strangers_device = issue(:app_session, owner: stranger, name: 'iPhone')
      personal

      sign_out(device)

      expect_signed_out(device)
      # One read for the three: a reload per token would be an N+1 of the spec.
      others = PersonalAccessToken.where(id: [other_device.id, personal.id, strangers_device.id])
      expect(others.count).to eq(3)
      expect(others.where.not(revoked_at: nil)).to be_empty
      get '/api/v1/me', headers: bearer(other_device)
      expect(response).to have_http_status(:ok)
    end

    it 'names nothing but the moment: no token, no account' do
      sign_out(device)

      expect_signed_out(device)
      expect(response.body).not_to include(device.token, PersonalAccessToken::TOKEN_PREFIX, 'person@example.com')
    end

    # Revoking is the way out. A token that no longer passes a validation of its
    # own (its only organisation is gone) still authenticates, so it must still
    # be able to sign out; a validating save refused it.
    it 'signs out a token that no longer passes its validation' do
      PersonalAccessTokenOrganisation.where(personal_access_token_id: personal.id).delete_all
      expect(personal.reload).not_to be_valid

      sign_out(personal)

      expect_signed_out(personal)
    end
  end

  # The revocation and its note are one write. If the note fails, nothing happened:
  # the token works, no answer is kept for the key, and the call can be repeated.
  # An answer of 200 here would name a moment for a token that is still alive.
  describe 'a sign-out that cannot be noted' do
    it 'answers 500 without the text of the error, leaves the token alive and keeps no answer' do
      allow_any_instance_of(User).to receive(:track_logout).and_raise(ActiveRecord::RecordInvalid, UserActivity.new)

      sign_out(device, headers: { 'Idempotency-Key' => 'sign-out-once' })

      expect(response).to have_http_status(:internal_server_error)
      expect(json).to eq('error' => 'internal_error', 'code' => 'refused', 'reason' => 'internal_error')
      expect(PersonalAccessToken.find(device.id)).not_to be_revoked
      expect(McpIdempotencyKey.count).to eq(0)

      # The control: the same call with the same key signs out once the note works.
      RSpec::Mocks.space.reset_all
      sign_out(device, headers: { 'Idempotency-Key' => 'sign-out-once' })
      expect_signed_out(device)
    end
  end

  describe 'a read-only token' do
    it 'gets 403 read_only and stays alive, a writing token signs out' do
      sign_out(read_only)

      expect(response).to have_http_status(:forbidden)
      expect(json).to eq('error' => 'forbidden', 'code' => 'read_only')
      expect(read_only.reload).not_to be_revoked
      get '/api/v1/me', headers: bearer(read_only)
      expect(response).to have_http_status(:ok)
      expect(UserActivity.where(user: user, action: 'logout')).to be_empty

      sign_out(personal)
      expect_signed_out(personal)
    end
  end

  describe 'without a token that works' do
    it 'answers 401 and revokes nothing' do
      device

      delete path
      expect(response).to have_http_status(:unauthorized)
      delete path, headers: { 'Authorization' => "Bearer #{PersonalAccessToken::TOKEN_PREFIX}#{'x' * 32}" }
      expect(response).to have_http_status(:unauthorized)
      expect(device.reload).not_to be_revoked

      sign_out(device)
      expect_signed_out(device)
    end

    it 'answers 401 for the token of a locked account, and signs out once the lock is gone' do
      user.lock_access!(send_instructions: false)

      sign_out(device)
      expect(response).to have_http_status(:unauthorized)
      expect(device.reload).not_to be_revoked

      user.unlock_access!
      sign_out(device)
      expect_signed_out(device)
    end
  end

  # Every write of /api/v1 takes the header. Here its answer is stored like any
  # other, and nobody can ask for it again: the replay sits inside authentication,
  # and the token is revoked by then.
  describe 'the Idempotency-Key header' do
    it 'is taken and its answer stored, and a repeat with the revoked token gets 401' do
      headers = { 'Idempotency-Key' => 'sign-out-once' }

      expect { sign_out(device, headers: headers) }.to change(McpIdempotencyKey, :count).by(1)
      expect_signed_out(device)
      first = response.body
      stored = JSON.parse(McpIdempotencyKey.where(personal_access_token_id: device.id).sole.response_content)
      expect(stored).to eq('status' => 200, 'body' => first)
      expect(stored['body']).not_to include(PersonalAccessToken::TOKEN_PREFIX)

      expect { sign_out(device, headers: headers) }.not_to change(McpIdempotencyKey, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a key the store cannot hold before anything is revoked, and signs out with a good one' do
      sign_out(device, headers: { 'Idempotency-Key' => 'k' * 300 })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json).to include('error' => 'invalid_idempotency_key', 'code' => 'invalid_input')
      expect(device.reload).not_to be_revoked

      sign_out(device, headers: { 'Idempotency-Key' => 'sign-out-once' })
      expect_signed_out(device)
    end
  end

  describe 'the activity of the account' do
    it 'notes a logout with the type app_session and the name of the token' do
      sign_out(device, headers: { 'User-Agent' => 'Lalabase/1.0 (iPhone; iOS 19.0)', 'REMOTE_ADDR' => '203.0.113.7' })

      expect_signed_out(device)
      activity = UserActivity.where(user: user, action: 'logout').sole
      expect(activity).to have_attributes(status: 'success', ip_address: '203.0.113.7',
                                          user_agent: 'Lalabase/1.0 (iPhone; iOS 19.0)')
      expect(activity.metadata).to include('logout_type' => 'app_session', 'device_name' => 'iPhone')
    end

    it 'keeps the type of the web sign-out unless told otherwise' do
      user.track_logout

      expect(UserActivity.where(user: user, action: 'logout').sole.metadata).to eq('logout_type' => 'manual')
    end

    it 'leaves the note of a sign-out on the web as it was' do
      sign_in user
      delete destroy_user_session_path

      expect(UserActivity.where(user: user, action: 'logout').sole.metadata).to eq('logout_type' => 'manual')
      expect(device.reload).not_to be_revoked
    end

    # The note reads the request through AppSessions::RequestFacts, like the sign-in.
    it 'signs out under a User-Agent the database would refuse, and still notes it' do
      sign_out(device, headers: { 'User-Agent' => "App\u0000/1.0" })

      expect_signed_out(device)
      expect(UserActivity.where(user: user, action: 'logout').sole.user_agent).to eq('App/1.0')
    end
  end

  # The base asks every action for an authorization. This controller answers with the
  # policy of the token and must never switch the question off.
  describe 'the authorization' do
    it 'keeps the tripwire of the base and asks the policy of the token' do
      filters = Api::V1::AppSessionsController._process_action_callbacks.select { |c| c.kind == :after }.map(&:filter)
      expect(filters).to include(:verify_authorized, :verify_policy_scoped)

      allow_any_instance_of(PersonalAccessTokenPolicy).to receive(:destroy?).and_return(false)
      sign_out(device)
      expect(response).to have_http_status(:forbidden)
      expect(device.reload).not_to be_revoked

      RSpec::Mocks.space.reset_all
      sign_out(device)
      expect_signed_out(device)
    end
  end

  describe 'what /api/v1/me says about it' do
    it 'names the endpoint app_session.revoke and the API version 1.15.0' do
      expect(Api::V1::Capabilities::ENDPOINTS['app_session.revoke']).to eq(['DELETE', '/api/v1/app_session'])
      expect(Api::V1::Capabilities::API_VERSION).to eq('1.15.0')

      get '/api/v1/me', headers: bearer(device)

      expect(json.dig('data', 'capabilities')).to include('app_session.revoke', 'app_sessions')
      expect(json.dig('data', 'api_version')).to eq('1.15.0')
    end
  end

  # The whole way of a device: in through the door, out through this call.
  describe 'after a sign-in through the door' do
    it 'signs the device out with the token the door handed out' do
      user.update!(password: 'password123', password_confirmation: 'password123')
      body = { user: { email: 'person@example.com', password: 'password123' }, device: { name: 'iPhone' } }
      post '/api/auth/v1/app_sessions', params: body.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:created)
      plaintext = json.dig('data', 'token')
      token = PersonalAccessToken.authenticate(plaintext)

      delete path, headers: { 'Authorization' => "Bearer #{plaintext}" }

      expect(response).to have_http_status(:ok)
      expect(token.reload).to be_revoked
      expect(PersonalAccessToken.authenticate(plaintext)).to be_nil
      expect(UserActivity.where(user: user).order(:created_at).pluck(:action)).to eq(%w[login logout])
    end
  end
end
