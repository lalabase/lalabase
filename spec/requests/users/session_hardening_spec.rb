# frozen_string_literal: true

require 'rails_helper'

# The sign-in and sign-out surface: CSRF on the login form, sign-out only via
# DELETE, the "deactivated" switch that actually signs a person out, and the
# lockout threshold. Every refusal has a control in the same group.
RSpec.describe 'Session hardening', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, active: true)
    end
  end

  def token_from(html)
    Nokogiri::HTML(html).at('input[name="authenticity_token"]')&.[]('value')
  end

  def signed_in?
    get edit_user_registration_path
    response.status == 200
  end

  describe 'login form with forgery protection on (as in production)' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    let(:credentials) { { user: { email: user.email, password: user.password } } }

    # A forged cross-site login would sign the victim into an account the
    # attacker controls.
    it 'does not sign in without the form token, and sends the visitor back to the form' do
      post user_session_path, params: credentials

      expect(response).to redirect_to(new_user_session_path)
      expect(signed_in?).to be(false)
    end

    it 'signs in with the token of the form' do
      get new_user_session_path
      post user_session_path, params: credentials.merge(authenticity_token: token_from(response.body))

      expect(signed_in?).to be(true)
    end
  end

  describe 'sign-out' do
    before { sign_in user }

    # sign_in takes effect on the next request; make the session real first.
    before { expect(signed_in?).to be(true) }

    it 'does not sign out through GET' do
      get destroy_user_session_path

      expect(response).to have_http_status(:not_found)
      expect(signed_in?).to be(true)
    end

    it 'signs out through DELETE' do
      delete destroy_user_session_path

      expect(signed_in?).to be(false)
    end
  end

  describe 'a deactivated account (users.active = false)' do
    it 'cannot sign in, and is told why' do
      user.update!(active: false)

      post user_session_path, params: { user: { email: user.email, password: user.password } }

      expect(flash[:alert]).to eq(I18n.t('devise.failure.account_deactivated'))
      expect(signed_in?).to be(false)
    end

    it 'loses a running session on the next request' do
      sign_in user
      expect(signed_in?).to be(true)

      user.update!(active: false)

      expect(signed_in?).to be(false)
    end

    it 'gets a 401 on the API' do
      pat = create(:personal_access_token, user: user, organisations: [organisation])
      user.update!(active: false)

      get '/api/v1/me', headers: { 'Authorization' => "Bearer #{pat.token}" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'lockout threshold' do
    # Twenty model calls in a row, not a request-scoped N+1.
    it 'locks the account on the 20th failed attempt, not before' do
      Prosopite.pause do
        19.times { user.valid_for_authentication? { false } }
        expect(user.reload.access_locked?).to be(false)

        user.valid_for_authentication? { false }
        expect(user.reload.access_locked?).to be(true)
      end
    end
  end
end
