# frozen_string_literal: true

require 'rails_helper'

# The public demo (Lalabase::Demo): one published login that every visitor shares.
# Each part is pinned twice, with the flag (what the demo needs) and without it
# (an instance that never set LALABASE_DEMO behaves as before).
RSpec.describe 'Demo mode', :ci_guard, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  # English, like the demo world: the refusal below is read in that language.
  let(:demo_user) do
    member(email: Lalabase::Demo.login_email, password: Lalabase::Demo::PASSWORD, language_preference: 'en')
  end
  let(:demo_on) { true }

  around do |example|
    flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
    ENV[Lalabase::Demo::ENV_FLAG] = demo_on ? Lalabase::Demo::ENABLED_VALUE : nil
    example.run
  ensure
    ENV[Lalabase::Demo::ENV_FLAG] = flag_was
  end

  def member(**attributes)
    user = create(:user, **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  def sign_in_with(email, password, session: self)
    session.post user_session_path, params: { user: { email: email, password: password } }
  end

  describe 'the sign-in page' do
    it 'shows the published login and no way to sign up' do
      get new_user_session_path

      demo = Nokogiri::HTML(response.body).at_css('form [data-testid="demo-login"]')
      expect(demo).to be_present
      expect(demo.text).to include(Lalabase::Demo.login_email, Lalabase::Demo::PASSWORD)
      expect(demo['data-demo-login-password-value']).to eq(Lalabase::Demo::PASSWORD)
      expect(response.body).not_to include(new_user_registration_path)
    end

    it 'lets a visitor in with it' do
      demo_user
      sign_in_with(Lalabase::Demo.login_email, Lalabase::Demo::PASSWORD)
      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="demo-banner"')
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'shows neither the login nor the banner' do
        get new_user_session_path
        expect(response.body).not_to include('data-testid="demo-login"')
        expect(response.body).to include(new_user_registration_path)

        sign_in demo_user
        get organisation_root_path(organisation)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('data-testid="demo-banner"')
      end
    end
  end

  describe 'search engines' do
    it 'are told not to index any response' do
      get new_user_session_path
      expect(response.headers['x-robots-tag']).to eq('noindex, nofollow')
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'are told nothing' do
        get new_user_session_path
        expect(response.headers['x-robots-tag']).to be_nil
      end
    end
  end

  # One account for everybody: Devise's lockout and the per-address throttle
  # would let any visitor shut out all the others.
  describe 'the shared login' do
    let(:too_many) { Devise.maximum_attempts + 5 }

    it 'is never locked by failed attempts' do
      demo_user
      Prosopite.pause { too_many.times { sign_in_with(Lalabase::Demo.login_email, 'wrong-password-123') } }

      expect(demo_user.reload).not_to be_access_locked
      sign_in_with(Lalabase::Demo.login_email, Lalabase::Demo::PASSWORD)
      expect(response).to redirect_to(organisation_root_path(organisation))
    end

    it 'leaves the lockout of every other address as it is' do
      other = member(email: 'jana@nordlicht.example')
      Prosopite.pause { too_many.times { sign_in_with(other.email, 'wrong-password-123') } }

      expect(other.reload).to be_access_locked
    end

    it 'stays signed in for one visitor while another signs in and out' do
      demo_user
      first = open_session
      second = open_session
      sign_in_with(Lalabase::Demo.login_email, Lalabase::Demo::PASSWORD, session: first)
      sign_in_with(Lalabase::Demo.login_email, Lalabase::Demo::PASSWORD, session: second)
      second.delete destroy_user_session_path

      first.get organisation_root_path(organisation)
      expect(first.response).to have_http_status(:ok)
      second.get organisation_root_path(organisation)
      expect(second.response.location).to eq(new_user_session_url)
    end

    describe 'per-address throttle' do
      around do |example|
        enabled_was = Rack::Attack.enabled
        store_was = Rack::Attack.cache.store
        Rack::Attack.enabled = true
        Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
        # One throttle bucket for the whole loop (see auth_throttle_spec.rb).
        travel_to(Time.current) { example.run }
        Prosopite.resume
        Rack::Attack.cache.store = store_was
        Rack::Attack.enabled = enabled_was
      end

      def attempts_from_many_addresses(email, count)
        Prosopite.pause
        count.times do |i|
          post user_session_path, params: { user: { email: email, password: 'wrong-password-123' } },
                                  headers: { 'REMOTE_ADDR' => "10.0.1.#{i + 1}" }
        end
      end

      it 'does not count the published address' do
        attempts_from_many_addresses(Lalabase::Demo.login_email.upcase, 10)
        expect(response).not_to have_http_status(:too_many_requests)
      end

      it 'still counts every other address' do
        attempts_from_many_addresses('jana@nordlicht.example', 6)
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe 'mail' do
    it 'goes nowhere' do
      with_delivered_mails { Devise::Mailer.reset_password_instructions(demo_user, 'token').deliver_later }
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'is delivered' do
        with_delivered_mails { Devise::Mailer.reset_password_instructions(demo_user, 'token').deliver_later }
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end
  end

  # One request per kind of restriction (DemoRestrictions::BLOCKED); the guard in
  # spec/architecture/demo_restrictions_guard_spec.rb covers the rest of the list.
  describe 'what a visitor cannot do' do
    let(:blocked) { I18n.t('views.demo.blocked', locale: :en) }

    before do
      sign_in demo_user
      ActsAsTenant.current_tenant = organisation
    end

    def expect_refused
      expect(response).to have_http_status(:see_other)
      expect(flash[:alert]).to eq(blocked)
    end

    it 'cannot change the email address or the password' do
      patch user_registration_path, params: { user: { email: 'visitor@example.com', password: 'another-password-1',
                                                      password_confirmation: 'another-password-1',
                                                      current_password: Lalabase::Demo::PASSWORD } }
      expect_refused
      expect(demo_user.reload.email).to eq(Lalabase::Demo.login_email)
      expect(demo_user.valid_password?(Lalabase::Demo::PASSWORD)).to be(true)
    end

    it 'cannot create an access token' do
      expect do
        post users_personal_access_tokens_path, params: { current_password: Lalabase::Demo::PASSWORD,
                                                          personal_access_token: { name: 'Script', expires_preset: '30' } }
      end.not_to change(PersonalAccessToken, :count)
      expect_refused
    end

    it 'cannot change the preferences stored on the shared person' do
      patch user_preferences_path, params: { current_section: 'language', user: { language_preference: 'de' } }
      expect_refused
      expect(demo_user.reload.language_preference).to eq('en')
    end

    it 'cannot invite anybody' do
      expect do
        post organisation_invitations_path(organisation), params: { invitation: { email: 'friend@example.com' } }
      end.not_to change(Invitation, :count)
      expect_refused
    end

    it 'cannot create an organisation' do
      expect { post create_organisation_path, params: { organisation: { name: 'Mine' } } }
        .not_to change(Organisation, :count)
      expect_refused
    end

    it 'answers a JSON request with 403' do
      post users_personal_access_tokens_path(format: :json)
      expect(response).to have_http_status(:forbidden)
    end

    it 'can still read the account page' do
      get edit_user_registration_path
      expect(response).to have_http_status(:ok)
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'is not refused' do
        get new_users_personal_access_token_path
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
