# frozen_string_literal: true

require 'rails_helper'

# Rate limits on the unauthenticated auth surface (registration hardening).
#
# Three defects are pinned here, all found while adding e-mail confirmation:
#
#   1. FORMAT-SUFFIX BYPASS (the serious one). Every throttle in
#      rack_attack.rb matched the bare path with `==`. Devise routes carry an
#      optional (.:format) segment, so `POST /users/sign_in.json` resolves to
#      users/sessions#create (verified via recognize_path) while
#      `req.path == '/users/sign_in'` is FALSE — the discriminator returns nil
#      and Rack::Attack skips the throttle entirely. Unlimited credential
#      stuffing, four characters of effort. Same defect class as the
#      detect_participants bypass (#244); `==` is no safer than `end_with?`
#      because req.path keeps the suffix. Only a prefix match is immune.
#   2. NO LIMIT ON REGISTRATION. POST /users had no throttle at all, only the
#      global 300/5min. Since the onboarding seed (S1) every signup creates
#      user + organisation + role + membership + tutorial project with tickets
#      and notifications, which makes unbounded signups an expensive flood.
#   3. NO LIMIT ON THE CONFIRMATION RESEND. :confirmable adds an endpoint that
#      mails an arbitrary address on demand — an open relay for harassment and
#      a fast way to burn the sender reputation.
#
# Mechanics: Rack::Attack is disabled in test and its cache defaults to the
# :null_store (which never counts), so each example flips both and restores
# them afterwards (convention from spec/requests/admin/sessions_spec.rb).
# Prosopite is paused inside the examples — N identical POSTs across N separate
# requests are a loop, not a request-scoped N+1.
RSpec.describe 'Auth endpoint throttling', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    enabled_was = Rack::Attack.enabled
    store_was = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    # Freeze the clock: the throttle counters bucket by Time.now / period, so a
    # request loop straddling a minute boundary splits across two buckets and
    # the expected 429 never comes — a real-clock flake that hit CI (guards run
    # 33892571092, password reset example). Frozen time = one bucket, always.
    travel_to(Time.current) { example.run }
    # Resume here, not in a before: the global before(:each) Prosopite.scan runs
    # after this around's setup, so pausing early would be silently undone.
    Prosopite.resume
    Rack::Attack.cache.store = store_was
    Rack::Attack.enabled = enabled_was
  end

  describe 'login (logins/ip, 5 per minute)' do
    let(:credentials) { { user: { email: 'nobody@example.com', password: 'wrong-password' } } }

    it 'lets the first 5 attempts through and throttles the 6th' do
      Prosopite.pause

      5.times { post user_session_path, params: credentials }
      expect(response).not_to have_http_status(:too_many_requests)

      post user_session_path, params: credentials
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'still throttles when a format suffix is appended (no .json bypass)' do
      # .json is the suffix that matters here: Devise answers a JSON login with
      # 401/200, so before the fix these six requests were fully processed
      # attempts — an attacker could tell hit from miss and was never counted.
      Prosopite.pause
      json_path = user_session_path(format: :json)

      6.times { post json_path, params: credentials }

      expect(response).to have_http_status(:too_many_requests)
    end

    # The per-email brake is what stops a distributed guess at ONE address
    # (a new IP per attempt). A JSON body put the address outside req.params,
    # so the brake never saw it.
    it 'counts attempts per address from rotating IPs, a JSON body included' do
      Prosopite.pause
      body = credentials.to_json
      json_headers = { 'CONTENT_TYPE' => 'application/json' }

      5.times do |i|
        post user_session_path(format: :json), params: body, headers: json_headers.merge('REMOTE_ADDR' => "10.0.0.#{i + 1}")
      end
      expect(response).not_to have_http_status(:too_many_requests)

      post user_session_path(format: :json), params: body, headers: json_headers.merge('REMOTE_ADDR' => '10.0.0.99')
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a trailing slash' do
      # The router accepts POST /users/sign_in/ as sessions#create, and req.path
      # keeps the slash. Before the FORMAT_SUFFIX `/?`, the \z-anchored regex
      # missed it and the throttle was skipped entirely.
      Prosopite.pause

      6.times { post '/users/sign_in/', params: credentials }

      expect(response).to have_http_status(:too_many_requests)
    end

    # Behind a proxy (REMOTE_ADDR is the proxy, a trusted address) the client's
    # address comes from a header. Caddy and nginx set X-Forwarded-For and pass
    # the client's own `Forwarded` header through untouched, and Rack read that
    # one first: a new `for=` per request was a new address per request, for
    # every throttle keyed on req.ip. A new address per attempt as well, so only
    # the per-IP brake can answer 429. Without X-Forwarded-For too: `Forwarded`
    # must not count as the fallback either.
    {
      'behind a proxy' => { 'X-Forwarded-For' => '203.0.113.5' },
      'without X-Forwarded-For' => {}
    }.each do |setting, proxy_headers|
      it "cannot be bypassed with a Forwarded header of the client (#{setting})" do
        Prosopite.pause

        6.times do |i|
          attempt = { user: { email: "nobody#{i}@example.com", password: 'wrong-password' } }
          post user_session_path, params: attempt, headers: proxy_headers.merge(
            'REMOTE_ADDR' => '172.18.0.5',
            'Forwarded' => "for=198.51.100.#{i + 1}"
          )
        end

        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  # The most privileged login in the app got the same rewrite as the others,
  # and a typo in ADMIN_LOG_IN_PATH would silently remove its brake — which is
  # precisely the failure class this whole change is about.
  describe 'admin login (admin_logins/ip + admin_logins/email, 5 per minute)' do
    let(:credentials) { { email: 'nobody@example.com', password: 'wrong-password' } }

    it 'throttles the 6th attempt on the bare path' do
      Prosopite.pause

      5.times { post admin_log_in_path, params: credentials }
      expect(response).not_to have_http_status(:too_many_requests)

      post admin_log_in_path, params: credentials
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a format suffix' do
      Prosopite.pause

      6.times { post admin_log_in_path(format: :html), params: credentials }

      expect(response).to have_http_status(:too_many_requests)
    end

    # The most privileged login in the app: //admin/log_in routes to
    # Admin::SessionsController#create and must not slip the throttle either.
    it 'cannot be bypassed with a doubled leading slash' do
      Prosopite.pause

      6.times { post '//admin/log_in', params: credentials }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe 'GDPR data export (data_exports/ip, 5 per hour)' do
    it 'cannot be bypassed with a format suffix' do
      # Unauthenticated: Rack::Attack sits BEFORE the controller auth in the
      # middleware stack, so every request is counted (redirected, but counted).
      Prosopite.pause

      6.times { post user_data_export_path(format: :html) }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe 'password reset (password_resets/ip, 3 per minute)' do
    let(:params) { { user: { email: 'nobody@example.com' } } }

    it 'still throttles when a format suffix is appended' do
      # .html, not .json: this controller is navigational and answers .json with
      # 406, so only a format it actually SERVES proves the bypass was
      # exploitable (here: an unbounded reset-mail cannon).
      Prosopite.pause

      4.times { post user_password_path(format: :html), params: params }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe 'registration (registrations/ip)' do
    # No terms_accepted and no bot-trap params: the request is rejected long
    # before anything is written, which keeps the loop cheap. Rack::Attack runs
    # in front of the whole controller and counts the request either way.
    let(:params) do
      {
        user: {
          first_name: 'Otto', last_name: 'Neuling',
          email: 'throttle@example.com',
          password: 'password123', password_confirmation: 'password123'
        }
      }
    end

    it 'lets the hourly allowance through and throttles the next request' do
      Prosopite.pause

      Rack::Attack::REGISTRATIONS_LIMIT.times { post user_registration_path, params: params }
      expect(response).not_to have_http_status(:too_many_requests)

      post user_registration_path, params: params
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a format suffix' do
      Prosopite.pause

      (Rack::Attack::REGISTRATIONS_LIMIT + 1).times do
        post user_registration_path(format: :html), params: params
      end

      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a trailing slash' do
      # POST /users/ resolves to registrations#create; req.path keeps the slash.
      Prosopite.pause

      (Rack::Attack::REGISTRATIONS_LIMIT + 1).times do
        post '/users/', params: params
      end

      expect(response).to have_http_status(:too_many_requests)
    end

    # //users and /users// both route to registrations#create (verified against
    # the booted router) and req.path keeps the padding, so a raw req.path.match?
    # skipped every throttle. normalized_path closes it. One example per form.
    %w[//users /users//].each do |padded|
      it "cannot be bypassed with the padded path #{padded}" do
        Prosopite.pause

        (Rack::Attack::REGISTRATIONS_LIMIT + 1).times { post padded, params: params }

        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  # Rotating the last octet is free for an attacker and defeats the per-IP
  # limit completely: 20 signups per address becomes 5100 per /24.
  describe 'registration across one /24 (registrations/subnet)' do
    let(:params) do
      {
        user: {
          first_name: 'Otto', last_name: 'Neuling',
          email: 'subnet@example.com',
          password: 'password123', password_confirmation: 'password123'
        }
      }
    end

    # Spread over enough addresses that the per-IP limit is never the reason
    # for the 429 -- otherwise this example would pass with the subnet rule
    # deleted.
    def post_from(offset)
      post user_registration_path, params: params,
                                   headers: { 'REMOTE_ADDR' => "203.0.113.#{offset % 254}" }
    end

    it 'throttles once the subnet limit is reached, spread over many addresses' do
      Prosopite.pause
      per_address = Rack::Attack::REGISTRATIONS_LIMIT - 1

      Rack::Attack::REGISTRATIONS_SUBNET_LIMIT.times { |i| post_from(i / per_address) }
      expect(response).not_to have_http_status(:too_many_requests)

      post_from(Rack::Attack::REGISTRATIONS_SUBNET_LIMIT / per_address)
      expect(response).to have_http_status(:too_many_requests)
    end

    # The neighbouring /24 is a different customer of the same provider and must
    # not inherit the block.
    it 'leaves a different subnet alone' do
      Prosopite.pause
      per_address = Rack::Attack::REGISTRATIONS_LIMIT - 1

      (Rack::Attack::REGISTRATIONS_SUBNET_LIMIT + 1).times { |i| post_from(i / per_address) }
      expect(response).to have_http_status(:too_many_requests)

      post user_registration_path, params: params, headers: { 'REMOTE_ADDR' => '203.0.114.7' }
      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  # The branches of the bucketing function the request specs above never
  # reach: IPv6, IPv4-mapped IPv6 and garbage input. Pinned directly.
  describe 'Rack::Attack.subnet_of' do
    it 'buckets a /24 together and the neighbouring /24 apart' do
      expect(Rack::Attack.subnet_of('203.0.113.7')).to eq(Rack::Attack.subnet_of('203.0.113.200'))
      expect(Rack::Attack.subnet_of('203.0.113.7')).not_to eq(Rack::Attack.subnet_of('203.0.114.7'))
    end

    it 'buckets IPv6 by /64' do
      expect(Rack::Attack.subnet_of('2001:db8:1:2:aaaa::1')).to eq(Rack::Attack.subnet_of('2001:db8:1:2:bbbb::9'))
      expect(Rack::Attack.subnet_of('2001:db8:1:2::1')).not_to eq(Rack::Attack.subnet_of('2001:db8:1:3::1'))
    end

    # ::ffff:a.b.c.d answers ipv6? with true; without unwrapping, ALL such
    # addresses share the single bucket "::" and one attacker could close
    # registration for every IPv4-mapped client at once.
    it 'treats an IPv4-mapped address like its plain IPv4 form' do
      expect(Rack::Attack.subnet_of('::ffff:203.0.113.7')).to eq(Rack::Attack.subnet_of('203.0.113.7'))
      expect(Rack::Attack.subnet_of('::ffff:203.0.113.7')).not_to eq(Rack::Attack.subnet_of('::ffff:198.51.100.7'))
    end

    # nil makes Rack::Attack skip the rule instead of throttling a bucket "".
    it 'answers nil for anything unparseable' do
      expect(Rack::Attack.subnet_of('not-an-ip')).to be_nil
      expect(Rack::Attack.subnet_of(nil)).to be_nil
    end
  end

  # The instance-wide watch is an alarm, NOT a limit: a global cap would let an
  # attacker close the front door for real customers. So the assertion is that
  # it logs and still lets the request through.
  describe 'instance-wide registration watch (registrations/global)' do
    let(:params) do
      {
        user: {
          first_name: 'Otto', last_name: 'Neuling',
          email: 'watch@example.com',
          password: 'password123', password_confirmation: 'password123'
        }
      }
    end

    it 'warns past the alert limit without ever answering 429' do
      Prosopite.pause
      warnings = []
      allow(Rails.logger).to receive(:warn) { |message| warnings << message.to_s }

      (Rack::Attack::REGISTRATIONS_GLOBAL_ALERT_LIMIT + 1).times do |i|
        # A DIFFERENT /24 each time, so neither the per-IP nor the subnet rule
        # can be the reason this stays under 429.
        post user_registration_path, params: params,
                                     headers: { 'REMOTE_ADDR' => "198.51.#{i}.7" }
      end

      expect(response).not_to have_http_status(:too_many_requests)
      expect(warnings).to include(a_string_matching(%r{RackAttack.*registrations/global}))
    end
  end

  describe 'confirmation resend (confirmations/ip, 3 per minute)' do
    # Without this throttle the endpoint mails any address on demand.
    let(:params) { { user: { email: 'nobody@example.com' } } }

    it 'throttles the 4th request' do
      Prosopite.pause

      3.times { post user_confirmation_path, params: params }
      expect(response).not_to have_http_status(:too_many_requests)

      post user_confirmation_path, params: params
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a format suffix' do
      Prosopite.pause

      4.times { post user_confirmation_path(format: :html), params: params }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  # The signature cannot be forged, but this endpoint opens sessions and an
  # honest visitor follows their link once.
  describe 'the one-time signup link (signup_handoff/ip, 10 per minute)' do
    it 'throttles the 11th request' do
      Prosopite.pause

      10.times { get users_signup_handoff_path(token: 'made-up') }
      expect(response).not_to have_http_status(:too_many_requests)

      get users_signup_handoff_path(token: 'made-up')
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a padded path' do
      Prosopite.pause

      11.times { get '//users/signup_handoff', params: { token: 'made-up' } }

      expect(response).to have_http_status(:too_many_requests)
    end

    # Rails serves a GET route for HEAD, so a rule that counts only GET leaves
    # the same endpoint reachable without a limit.
    it 'counts HEAD as well' do
      Prosopite.pause

      11.times { head users_signup_handoff_path(token: 'made-up') }

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
