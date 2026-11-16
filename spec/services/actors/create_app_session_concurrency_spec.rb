# frozen_string_literal: true

require 'rails_helper'

# What: two sign-ins of one account at the same moment, at the limit of ten devices.
# Why: each counts the live devices, revokes the surplus and adds its own. Without the
#   lock on the row of the user both count ten, both revoke the same device, and the
#   account ends with eleven: the limit would hold only for people who sign in slowly.
#   Real commits and two connections, so the second sign-in really waits.
RSpec.describe Actors::CreateAppSession, :ci_guard do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after { Prosopite.resume }

  def sign_in(account_id, device_name)
    ActiveRecord::Base.connection_pool.with_connection do
      described_class.call(current_user: User.find(account_id), device_name: device_name)
    end
  end

  it 'ends with ten live devices when two sign-ins of one account run at once' do
    user = create(:user, organisation: create(:organisation))
    devices = Array.new(10) do |index|
      create(:personal_access_token, :app_session, user: user, last_used_at: (index + 1).days.ago)
    end

    # The first sign-in has made room and holds its transaction open while the
    # second starts: with the lock the second waits here, without it it slips past.
    first_has_room = Queue.new
    allow(PersonalAccessToken).to receive(:make_room_for_app_session!).and_wrap_original do |original, account|
      revoked = original.call(account)
      if Thread.current[:first_sign_in]
        first_has_room << true
        sleep 0.4
      end
      revoked
    end

    first = Thread.new do
      Thread.current[:first_sign_in] = true
      sign_in(user.id, 'Erstes Gerät')
    end
    second = Thread.new do
      first_has_room.pop
      sign_in(user.id, 'Zweites Gerät')
    end
    results = [first, second].map { |thread| thread.join(15)&.value }

    expect(results).to all(be_success)
    live = PersonalAccessToken.active.app_sessions.where(user: user)
    expect(live.count).to eq(PersonalAccessToken::MAX_APP_SESSIONS)
    expect(live.pluck(:name)).to include('Erstes Gerät', 'Zweites Gerät')
    # Each sign-in revoked a device of its own: the two unused longest.
    expect(PersonalAccessToken.where(user: user).where.not(revoked_at: nil)).to match_array(devices.last(2))
  ensure
    [first, second].each { |thread| thread&.kill if thread&.alive? }
  end
end
