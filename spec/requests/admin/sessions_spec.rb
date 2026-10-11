# frozen_string_literal: true

require 'rails_helper'

# Regression + hardening suite for the admin login (Plan
# doc/admin_account_owner_plan.md, Baustein B, D4/D5/D8/D10).
#
# Request spec (not controller spec) on purpose -- the D8 key-separation cases
# need a REAL Devise app session alongside the admin session in the same browser,
# which only the full Rack/Warden stack exercised by request specs provides.
#
# The load-bearing invariants under test:
#   * D4  -- inactive admins are refused at login AND thrown out mid-session.
#   * D5  -- reset_session on a successful login (fixation + id rotation); a
#            Devise app session in the same browser ends as an accepted effect.
#   * D8  -- the admin session lives under its OWN key (session[:beuser_id]),
#            disjoint from Devise's session[:user_id]; failure paths delete only
#            that key (never reset_session -> no drive-by logout of app users).
#   * D10 -- 10/3min brute-force brake on the login.
RSpec.describe 'Admin::Sessions', type: :request do
  let(:password) { attributes_for(:beuser)[:password] }
  let(:admin_beuser) { create(:beuser, role: 'admin', active: true) }

  def log_in(email:, pass: password)
    post admin_log_in_path, params: { email: email, password: pass }
  end

  describe 'POST /admin/log_in (regression)' do
    it 'logs in an active admin beuser and stores its own session key' do
      log_in(email: admin_beuser.email)

      expect(response).to redirect_to(admin_dashboard_path)
      expect(session[:beuser_id]).to eq(admin_beuser.id)
    end

    it 'refuses a wrong password without setting a session' do
      log_in(email: admin_beuser.email, pass: 'wrong-password')

      expect(response).to redirect_to(admin_log_in_path)
      expect(session[:beuser_id]).to be_blank
    end

    it 'refuses a non-admin beuser (operator-gated)' do
      non_admin = create(:beuser, role: 'user', active: true)

      log_in(email: non_admin.email)

      expect(response).to redirect_to(admin_log_in_path)
      expect(session[:beuser_id]).to be_blank
    end

    it 'refuses an inactive admin beuser (D4)' do
      inactive = create(:beuser, role: 'admin', active: false)

      log_in(email: inactive.email)

      expect(response).to redirect_to(admin_log_in_path)
      expect(session[:beuser_id]).to be_blank
    end

    # D8: the login must write ONLY the admin key, never Devise's session[:user_id]
    # (whose collision with the old admin key was the P1 the whole PR fixes).
    it 'writes session[:beuser_id], never session[:user_id]' do
      log_in(email: admin_beuser.email)

      expect(session[:beuser_id]).to eq(admin_beuser.id)
      expect(session[:user_id]).to be_blank
    end
  end

  describe 'per-request re-check (D4/D8)' do
    # Another active admin does the demoting: the last one cannot lose the role.
    before do
      create(:beuser)
      log_in(email: admin_beuser.email)
    end

    it 'throws out a beuser deactivated mid-session and clears the key' do
      get admin_organisations_path
      expect(response).to have_http_status(:ok)

      admin_beuser.update!(active: false)

      get admin_organisations_path
      expect(response).to redirect_to(admin_log_in_path)
      expect(session[:beuser_id]).to be_blank
    end

    it 'throws out a beuser demoted to non-admin mid-session and clears the key' do
      get admin_organisations_path
      expect(response).to have_http_status(:ok)

      admin_beuser.update!(role: 'user')

      get admin_organisations_path
      expect(response).to redirect_to(admin_log_in_path)
      expect(session[:beuser_id]).to be_blank
    end
  end

  describe 'session-fixation protection (reset_session on login, D5)' do
    # reset_session rotates the session id and wipes any prior session data; we
    # assert its observable effect: a Devise app session in the same browser ends.
    it 'ends an existing Devise app session when an admin logs in' do
      sign_in create(:user)
      get new_user_session_path # materialise the warden session
      expect(response).to have_http_status(:redirect) # signed-in user is redirected away

      log_in(email: admin_beuser.email)
      expect(session[:beuser_id]).to eq(admin_beuser.id)

      get new_user_session_path # app session was reset -> login form renders again
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'key separation between admin and Devise app session (D8)' do
    it 'redirects an app user who visits /admin without ending their Devise session' do
      sign_in create(:user)
      get new_user_session_path
      expect(response).to have_http_status(:redirect) # signed in

      get admin_organisations_path # no beuser_id -> admin redirect, no reset_session
      expect(response).to redirect_to(admin_log_in_path)

      get new_user_session_path
      expect(response).to have_http_status(:redirect) # app session survived
    end

    it 'keeps the admin session alive when an app user signs in in the same browser' do
      log_in(email: admin_beuser.email)
      expect(session[:beuser_id]).to eq(admin_beuser.id)

      sign_in create(:user) # a Devise app login writes session[:user_id], not beuser_id

      get admin_organisations_path
      expect(response).to have_http_status(:ok)
      expect(session[:beuser_id]).to eq(admin_beuser.id)
    end
  end

  describe 'GET /admin/log_out' do
    it 'clears the admin key and redirects to login' do
      log_in(email: admin_beuser.email)
      expect(session[:beuser_id]).to be_present

      get admin_log_out_path

      expect(response).to redirect_to(admin_log_in_path)
      expect(session[:beuser_id]).to be_blank
    end

    it 'preserves a concurrent Devise app session (only beuser_id is cleared, D8)' do
      log_in(email: admin_beuser.email)
      sign_in create(:user)
      get admin_organisations_path # materialise warden session next to the admin one
      expect(response).to have_http_status(:ok)

      get admin_log_out_path
      expect(response).to redirect_to(admin_log_in_path)

      get new_user_session_path
      expect(response).to have_http_status(:redirect) # app session survived the admin logout
    end
  end

  describe 'brute-force protection (rate_limit 10/3min, D10)' do
    around do |example|
      # Isolate the CONTROLLER-level rate_limit (D10, 10/3min, redirect + flash)
      # from the Rack::Attack middleware throttle (admin_logins/ip, 5/60s, plain
      # 429): the increment reroute below revives the middleware counter too
      # (both default to Rails.cache), and 5/60s would trip first.
      rack_attack_was = Rack::Attack.enabled
      Rack::Attack.enabled = false
      example.run
      Rack::Attack.enabled = rack_attack_was
      Prosopite.resume
    end

    before do
      # rate_limit binds its store at class-load time to config.cache_store, which
      # is :null_store in test (NullStore#increment always returns nil -> never
      # limits). Reroute increment on that exact instance -- the one captured in
      # the before_action closure -- to a real counting store so the limit trips.
      counter = ActiveSupport::Cache::MemoryStore.new
      allow(ActionController::Base.cache_store)
        .to receive(:increment) { |name, amount = 1, **opts| counter.increment(name, amount, **opts) }
    end

    it 'processes the first 10 attempts normally and limits the 11th (boundary n / n+1)' do
      # 11 identical Beuser.find_by across 11 independent login POSTs is a loop of
      # separate requests, not a request-scoped N+1 -- pause the per-example scan.
      Prosopite.pause

      invalid = I18n.t('flash.admin.sessions.invalid_credentials')
      limited = I18n.t('shared.errors.rate_limit')

      # Attempts 1..9: clearly under the limit, each a normal invalid-credentials
      # failure. Distinguishing the flash from `limited` is what makes the
      # boundary assertions below meaningful (both outcomes redirect to login,
      # so the redirect target alone cannot tell "processed" from "throttled").
      9.times do
        log_in(email: admin_beuser.email, pass: 'wrong-password')
        expect(flash[:alert]).to eq(invalid)
      end

      # Attempt 10 (boundary n) is the LAST one still processed normally. A
      # `to: 9` off-by-one would already throttle here -> this assertion dies.
      log_in(email: admin_beuser.email, pass: 'wrong-password')
      expect(flash[:alert]).to eq(invalid)

      # Attempt 11 (n+1) is the FIRST one the limiter blocks. A `to: 11` off-by-one
      # would still process it (invalid flash) -> this assertion dies.
      log_in(email: admin_beuser.email, pass: 'wrong-password')
      expect(response).to redirect_to(admin_log_in_path)
      expect(flash[:alert]).to eq(limited)
    end
  end

  # F5: the admin login must be throttled per EMAIL, not only per IP -- otherwise
  # distributed credential stuffing against one known admin email (one attempt
  # per rotating IP) is unbounded. Uses the real Rack::Attack middleware with a
  # counting cache store (the app default Rails.cache is :null_store in test, so
  # throttles never fire without this).
  describe 'brute-force protection per email across rotating IPs (rack_attack admin_logins/email, F5)' do
    around do |example|
      enabled_was = Rack::Attack.enabled
      store_was = Rack::Attack.cache.store
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
      # Prosopite.pause is set INSIDE each example (after the global
      # before(:each) Prosopite.scan has run); resume here restores it for the
      # rest of the suite. Pausing in this around would run before that scan and
      # be silently re-enabled, leaking the login loop's repeated Beuser.find_by
      # into the next example -- exactly the false N+1 this guards against.
      Prosopite.resume
      Rack::Attack.cache.store = store_was
      Rack::Attack.enabled = enabled_was
    end

    def log_in_from(ip:, email:, pass: 'wrong-password')
      post admin_log_in_path, params: { email: email, password: pass },
                              headers: { 'REMOTE_ADDR' => ip }
    end

    # admin_logins/email is 5/60s. Rotating the client IP on every attempt
    # neutralises the IP-keyed throttle (admin_logins/ip, also 5/60s), so ONLY
    # the email throttle can block the 6th -- proving F5 keys on the email. A
    # mutation that keyed on IP instead, or dropped the throttle, would let the
    # 6th attempt through and fail this.
    it 'blocks the 6th attempt on the same email even from a fresh IP each time' do
      Prosopite.pause # a loop of separate login POSTs, not a request-scoped N+1

      5.times do |i|
        log_in_from(ip: "203.0.113.#{i}", email: admin_beuser.email)
        expect(response).not_to have_http_status(:too_many_requests)
      end

      log_in_from(ip: '203.0.113.99', email: admin_beuser.email)

      expect(response).to have_http_status(:too_many_requests)
    end

    # Guard against a mutation that keys the email throttle on the wrong param
    # (or globally): a DIFFERENT email from a fresh IP must still be accepted for
    # processing even after another email has been throttled.
    it 'does not block a different email that has its own fresh attempt budget' do
      Prosopite.pause

      6.times { |i| log_in_from(ip: "203.0.113.#{i}", email: admin_beuser.email) }

      log_in_from(ip: '198.51.100.1', email: 'someone-else@example.com')

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end
end
