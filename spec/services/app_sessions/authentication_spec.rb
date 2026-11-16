# frozen_string_literal: true

require 'rails_helper'

# What: AppSessions::Authentication checks an address and a password the way Devise
#   does for the web form, without Warden.
# Why: the sign-in door of clients does not run through Warden, so the hooks that
#   count, lock, reset and ask "may this account sign in" do not fire there. This
#   object asks each question itself, and each one is pinned here beside its success.
RSpec.describe AppSessions::Authentication, :ci_guard do
  let(:password) { 'password123' }
  let!(:user) { create(:user, email: 'person@example.com', password: password) }

  def attempt(email: 'person@example.com', password: 'password123')
    described_class.call(email: email, password: password)
  end

  it 'answers the account for the right password' do
    result = attempt

    expect(result).to be_success
    expect(result.user).to eq(user)
    expect(result.failure).to be_nil
  end

  it 'answers invalid_credentials and no account for a wrong password, and counts it' do
    result = attempt(password: 'wrong-password')

    expect(result).not_to be_success
    expect(result).to have_attributes(user: nil, failure: :invalid_credentials)
    expect(user.reload.failed_attempts).to eq(1)
    expect(attempt).to be_success
  end

  it 'answers invalid_credentials for an unknown address, after hashing a password for nothing' do
    hashed = []
    allow(User).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |built| allow(built).to receive(:password=) { |value| hashed << value } }
    end

    result = attempt(email: 'nobody@example.com', password: 'a-guess')

    expect(result).to have_attributes(user: nil, failure: :invalid_credentials)
    expect(hashed).to eq(['a-guess'])
    # The control: a known address hashes nothing for show.
    hashed.clear
    expect(attempt).to be_success
    expect(hashed).to be_empty
  end

  it 'finds the address like Devise: case and outer spaces do not count' do
    expect(attempt(email: '  PERSON@example.COM ')).to be_success
    expect(attempt(email: 'person2@example.com')).not_to be_success
  end

  it 'never answers the system account' do
    system_account = User.system

    result = attempt(email: system_account.email, password: 'anything')

    expect(result).to have_attributes(user: nil, failure: :invalid_credentials)
    expect(system_account.reload.failed_attempts).to eq(0)
  end

  describe 'a locked account' do
    before { user.lock_access!(send_instructions: false) }

    it 'answers invalid_credentials for the right password too, and counts the attempt' do
      result = attempt

      expect(result).to have_attributes(user: nil, failure: :invalid_credentials)
      expect(user.reload.failed_attempts).to eq(1)
      expect(user).to be_access_locked
    end

    it 'signs in again once the lock has run out, and the counter is back at 0' do
      user.update_columns(locked_at: (Devise.unlock_in + 1.minute).ago, failed_attempts: 20)

      expect(attempt).to be_success
      expect(user.reload).to have_attributes(failed_attempts: 0, locked_at: nil)
    end
  end

  describe 'an account that may not sign in' do
    it 'names email_unconfirmed for the right password only' do
      user.update_columns(confirmed_at: nil, created_at: (Devise.allow_unconfirmed_access_for + 1.day).ago)

      expect(attempt).to have_attributes(user: nil, failure: :email_unconfirmed)
      expect(attempt(password: 'wrong-password')).to have_attributes(failure: :invalid_credentials)

      user.update_columns(confirmed_at: Time.current)
      expect(attempt).to be_success
    end

    it 'names account_deactivated for the right password only' do
      user.update_columns(active: false)

      expect(attempt).to have_attributes(user: nil, failure: :account_deactivated)
      expect(attempt(password: 'wrong-password')).to have_attributes(failure: :invalid_credentials)

      user.update_columns(active: true)
      expect(attempt).to be_success
    end

    it 'turns a reason it does not know into invalid_credentials, never into a new value' do
      allow_any_instance_of(User).to receive(:active_for_authentication?).and_return(false)
      allow_any_instance_of(User).to receive(:inactive_message).and_return(:second_factor_missing)

      expect(attempt).to have_attributes(user: nil, failure: :invalid_credentials)
      expect(described_class::INACTIVE_REASONS.values).to contain_exactly(:email_unconfirmed, :account_deactivated)
    end
  end

  describe 'the counter' do
    it 'is reset by a success' do
      user.update_columns(failed_attempts: 7)

      expect(attempt).to be_success
      expect(user.reload.failed_attempts).to eq(0)
    end

    it 'is not reset when the right password meets an account that may not sign in' do
      user.update_columns(active: false, failed_attempts: 7)

      expect(attempt).not_to be_success
      expect(user.reload.failed_attempts).to eq(7)
    end
  end

  describe 'the activity log' do
    it 'notes a failed login for a known account, with the reason, and nothing for a success' do
      attempt(password: 'wrong-password')
      expect(UserActivity.where(user: user).sole).to have_attributes(action: 'login_failed', status: 'failed',
                                                                     failure_reason: 'Invalid password')

      expect { attempt }.not_to change(UserActivity, :count)
    end

    it 'notes nothing for an unknown address' do
      expect { attempt(email: 'nobody@example.com') }.not_to change(UserActivity, :count)
    end

    # Only a known account is noted. A note that raised would be an answer an
    # unknown address never gives, so it must not decide the refusal.
    it 'refuses the same way when the note of a failed login raises, and still counts the attempt' do
      allow_any_instance_of(User).to receive(:track_failed_login).and_raise(ActiveRecord::StatementInvalid, 'no')

      wrong = attempt(password: 'wrong-password')
      expect(wrong.failure).to eq(:invalid_credentials)
      expect(user.reload.failed_attempts).to eq(1)

      user.update_columns(active: false, failed_attempts: 0)
      expect(attempt.failure).to eq(:account_deactivated)

      # The control: without the failing note the same attempt is noted.
      RSpec::Mocks.space.reset_all
      user.update_columns(active: true)
      expect { attempt(password: 'wrong-password') }.to change(UserActivity, :count).by(1)
    end
  end
end
