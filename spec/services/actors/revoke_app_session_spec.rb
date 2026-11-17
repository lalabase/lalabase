# frozen_string_literal: true

require 'rails_helper'

# What: Actors::RevokeAppSession signs a token out, as one write: the revocation and its
#   note in the activity log.
# Why: the sign-out of clients hands it the token of the request. It must end that token
#   once, note it once, and never end the token of somebody else, whoever calls it.
RSpec.describe Actors::RevokeAppSession, :ci_guard do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:device) { create(:personal_access_token, :app_session, user: user, name: 'iPhone') }

  def call(token: device, current_user: user)
    described_class.call(current_user: current_user, token: token)
  end

  def logouts
    UserActivity.where(user: user, action: 'logout')
  end

  it 'revokes the token and notes the logout with the type app_session and the name of the token' do
    freeze_time do
      result = call

      expect(result).to be_success
      expect(result.resource).to eq(device)
      expect(device.reload.revoked_at).to eq(Time.current)
      expect(logouts.sole.metadata).to include('logout_type' => 'app_session', 'device_name' => 'iPhone')
    end
  end

  # Two calls that both read the token before either wrote: the first revocation is
  # the one that happened, and it is noted once.
  it 'keeps the first moment and the one note when the token is revoked already' do
    copy = PersonalAccessToken.find(device.id)

    travel_to(Time.zone.local(2026, 3, 1, 12, 0, 0)) { expect(call).to be_success }
    first = device.reload.revoked_at
    second = travel_to(Time.zone.local(2026, 3, 1, 12, 0, 5)) { call(token: copy) }

    expect(second).to be_success
    expect(second.resource.revoked_at).to eq(first)
    expect(device.reload.revoked_at).to eq(first)
    expect(logouts.count).to eq(1)
  end

  # The token is the caller's own by construction. A token of another account is a
  # mistake of the caller: it raises, in every environment, and ends nothing.
  it 'raises for the token of another account, and signs the owner out' do
    stranger = create(:user, organisation: organisation)
    # As in production, where an actor turns an unexpected error into a failure:
    # this one must not become a polite answer.
    reraise_was = Rails.application.config.x.actors.reraise_unexpected
    Rails.application.config.x.actors.reraise_unexpected = false

    expect { call(current_user: stranger) }.to raise_error(ArgumentError)
    expect(device.reload).not_to be_revoked
    expect(UserActivity.where(action: 'logout')).to be_empty

    expect(call).to be_success
    expect(device.reload).to be_revoked
  ensure
    Rails.application.config.x.actors.reraise_unexpected = reraise_was
  end

  it 'revokes nothing when the note fails, and revokes once it works' do
    allow(user).to receive(:track_logout).and_raise(ActiveRecord::RecordInvalid, UserActivity.new)

    result = call

    expect(result).not_to be_success
    expect(PersonalAccessToken.find(device.id)).not_to be_revoked
    expect(logouts).to be_empty

    RSpec::Mocks.space.reset_all
    expect(call).to be_success
    expect(device.reload).to be_revoked
  end

  it 'leaves Current.user as it was' do
    Current.user = nil

    call

    expect(Current.user).to be_nil
  end
end
