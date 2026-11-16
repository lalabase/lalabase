# frozen_string_literal: true

require 'rails_helper'

# What: Actors::CreateAppSession signs a device in, as one write: room for it, its
#   token, the login in the activity log.
# Why: the token it makes reaches the whole account and may write. Its shape and the
#   limit of ten devices must hold whoever calls the actor.
RSpec.describe Actors::CreateAppSession, :ci_guard do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }

  def call(device_name: 'iPhone', current_user: user)
    described_class.call(current_user: current_user, device_name: device_name)
  end

  it 'makes a device token for the whole account that may write, alive for 90 days' do
    freeze_time do
      result = call

      expect(result).to be_success
      token = result.resource
      expect(token).to be_persisted
      expect(token).to have_attributes(kind: 'app_session', name: 'iPhone', user: user, all_organisations: true,
                                       read_only: false, expires_at: 90.days.from_now, revoked_at: nil,
                                       last_used_at: nil)
      expect(token.ends_at).to eq(365.days.from_now)
      expect(token.personal_access_token_organisations).to be_empty
    end
  end

  it 'hands the plaintext out on the record, once, and stores its digest only' do
    token = call.resource

    expect(token.token).to match(/\A#{PersonalAccessToken::TOKEN_PREFIX}[A-Za-z0-9]{32}\z/o)
    expect(PersonalAccessToken.authenticate(token.token)).to eq(token)
    expect(PersonalAccessToken.find(token.id).token).to be_nil
    expect(token.attributes.values.map(&:to_s)).not_to include(token.token)
  end

  it 'notes the login with the method app_session and the device name' do
    call(device_name: 'iPad')

    activity = UserActivity.where(user: user).sole
    expect(activity).to have_attributes(action: 'login', status: 'success')
    expect(activity.metadata).to include('login_method' => 'app_session', 'device_name' => 'iPad')
  end

  it 'leaves Current.user as it was' do
    Current.user = nil

    call

    expect(Current.user).to be_nil
  end

  it 'revokes the device unused longest for the eleventh, never a personal token' do
    personal = create(:personal_access_token, user: user, organisations: [organisation], last_used_at: 80.days.ago)
    devices = Array.new(10) { |i| create(:personal_access_token, :app_session, user: user, last_used_at: (i + 1).days.ago) }

    result = call(device_name: 'Elftes')

    expect(result).to be_success
    expect(PersonalAccessToken.where(user: user).where.not(revoked_at: nil)).to contain_exactly(devices.last)
    expect(personal.reload).not_to be_revoked
    expect(PersonalAccessToken.active.app_sessions.where(user: user).count).to eq(PersonalAccessToken::MAX_APP_SESSIONS)
  end

  it 'leaves the devices of another account alone' do
    other = create(:user, organisation: organisation)
    theirs = Array.new(10) { |i| create(:personal_access_token, :app_session, user: other, last_used_at: (i + 1).days.ago) }

    expect(call).to be_success

    expect(PersonalAccessToken.where(id: theirs.map(&:id)).where.not(revoked_at: nil)).to be_empty
  end

  # One transaction: a token without its login entry, or a revoked device without
  # the token that took its place, must not stay behind.
  it 'writes nothing when a step fails: no token, no revoked device' do
    devices = Array.new(10) { |i| create(:personal_access_token, :app_session, user: user, last_used_at: (i + 1).days.ago) }

    result = call(device_name: 'x' * 256)

    expect(result).not_to be_success
    expect(result.code).to eq(:validation_failed)
    expect(PersonalAccessToken.where(id: devices.map(&:id)).where.not(revoked_at: nil)).to be_empty
    expect(PersonalAccessToken.where(user: user).count).to eq(10)
    expect(UserActivity.where(user: user)).to be_empty

    # The control: the same call with a name that fits.
    expect(call(device_name: 'x' * 255)).to be_success
  end

  describe 'User#track_login, the parameter this actor added' do
    it 'keeps the method of the web form unless told otherwise' do
      user.track_login

      expect(UserActivity.where(user: user).sole.metadata).to include('login_method' => 'standard')
      expect(UserActivity.where(user: user).sole.metadata).not_to have_key('device_name')
    end
  end
end
