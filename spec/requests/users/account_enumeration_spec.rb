# frozen_string_literal: true

require 'rails_helper'

# The pages a visitor reaches without a session must not tell whether an address
# has an account. For an agency, the list of its clients' people is sensitive:
# "Falls deine E-Mail-Adresse existiert ..." for one address and "nicht gefunden"
# for another answers the question the visitor should not be able to ask.
#
# Devise answers the same for both only with `config.paranoid = true`. Until
# 2026-11-15 it was off, and password reset, confirmation resend and unlock each
# said "not found" for an unknown address. The sign-in form said "Dein Konto ist
# gesperrt" for a locked account even with a wrong password, which proves the
# account exists.
#
# Each comparison has a control: the known address still gets its mail, so a
# change that silenced both answers would not pass as a fix.
#
# Not covered here: the registration form still says an address is taken. Devise's
# paranoid mode does not reach registerable; that answer is a decision of its own.
RSpec.describe 'Account enumeration on the pages without a session', :ci_guard, type: :request do
  let!(:known) { create(:user, email: 'known@example.com') }
  let(:unknown_email) { 'nobody-here@example.com' }

  before { ActionMailer::Base.deliveries.clear }

  # What a visitor sees of an answer: status, where it sends them, what it says.
  def answer
    { status: response.status, location: response.location, flash: flash.to_hash }
  end

  def answer_for(email)
    yield email
    result = answer
    reset!
    result
  end

  def mails_to(email)
    ActionMailer::Base.deliveries.count { |mail| mail.to.include?(email) }
  end

  shared_examples 'the same answer for a known and an unknown address' do
    it 'answers both addresses alike' do
      known_answer = answer_for(known.email) { |email| request_for(email) }
      unknown_answer = answer_for(unknown_email) { |email| request_for(email) }

      expect(known_answer[:flash]).to be_present
      expect(unknown_answer).to eq(known_answer)
    end
  end

  describe 'password reset' do
    def request_for(email)
      post user_password_path, params: { user: { email: email } }
    end

    it_behaves_like 'the same answer for a known and an unknown address'

    # Devise mails through deliver_later (User#send_devise_notification).
    it 'still mails the known address' do
      with_delivered_mails { request_for(known.email) }

      expect(mails_to(known.email)).to eq(1)
    end
  end

  describe 'confirmation resend' do
    let!(:known) { create(:user, :unconfirmed, email: 'known@example.com') }

    def request_for(email)
      post user_confirmation_path, params: { user: { email: email } }
    end

    it_behaves_like 'the same answer for a known and an unknown address'

    # Devise mails through deliver_later (User#send_devise_notification).
    it 'still mails the known address' do
      with_delivered_mails { request_for(known.email) }

      expect(mails_to(known.email)).to eq(1)
    end

    # "bereits bestätigt" would be the same leak through another door.
    it 'answers an address that is already confirmed like an unknown one' do
      known.confirm
      confirmed_answer = answer_for(known.email) { |email| request_for(email) }
      unknown_answer = answer_for(unknown_email) { |email| request_for(email) }

      expect(confirmed_answer).to eq(unknown_answer)
    end
  end

  describe 'unlock' do
    before { known.lock_access!(send_instructions: false) }

    def request_for(email)
      post user_unlock_path, params: { user: { email: email } }
    end

    it_behaves_like 'the same answer for a known and an unknown address'

    # Devise mails through deliver_later (User#send_devise_notification).
    it 'still mails the known address' do
      with_delivered_mails { request_for(known.email) }

      expect(mails_to(known.email)).to eq(1)
    end

    # "war nicht gesperrt" would be the same leak through another door.
    it 'answers an account that is not locked like an unknown one' do
      known.unlock_access!
      not_locked_answer = answer_for(known.email) { |email| request_for(email) }
      unknown_answer = answer_for(unknown_email) { |email| request_for(email) }

      expect(not_locked_answer).to eq(unknown_answer)
    end
  end

  describe 'sign-in' do
    def request_for(email)
      post user_session_path, params: { user: { email: email, password: 'wrong-password' } }
    end

    it 'answers a wrong password for a known address like an unknown address' do
      known_answer = answer_for(known.email) { |email| request_for(email) }
      unknown_answer = answer_for(unknown_email) { |email| request_for(email) }

      expect(known_answer[:status]).to eq(422).or eq(302)
      expect(unknown_answer).to eq(known_answer)
    end

    # The lock message came before the password check: a wrong password on a
    # locked account proved that the account exists.
    it 'does not say that an account is locked' do
      known.lock_access!(send_instructions: false)
      locked_answer = answer_for(known.email) { |email| request_for(email) }
      unknown_answer = answer_for(unknown_email) { |email| request_for(email) }

      expect(locked_answer).to eq(unknown_answer)
    end
  end
end
