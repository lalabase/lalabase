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

  # The sign-in door of clients (POST /api/auth/v1/app_sessions) counts in the two
  # buckets of the web sign-in. A bucket of its own would double the guesses per
  # address and per minute, and a path matched by hand would reopen the padding
  # bypass.
  describe 'app sign-in (shares logins/ip and logins/email with the web, 5 per minute)' do
    let(:app_path) { '/api/auth/v1/app_sessions' }
    let(:json_headers) { { 'CONTENT_TYPE' => 'application/json' } }

    def app_attempt(email: 'nobody@example.com', ip: nil, path: app_path)
      headers = ip ? json_headers.merge('REMOTE_ADDR' => ip) : json_headers
      post path, params: { user: { email: email, password: 'wrong-password' }, device: { name: 'iPhone' } }.to_json,
                 headers: headers
    end

    def web_attempt(email: 'nobody@example.com', ip: nil)
      post user_session_path, params: { user: { email: email, password: 'wrong-password' } },
                              headers: ip ? { 'REMOTE_ADDR' => ip } : {}
    end

    it 'lets the first 5 attempts of an address through and throttles the 6th, with the RateLimit headers' do
      Prosopite.pause

      5.times { |i| app_attempt(email: "nobody#{i}@example.com") }
      expect(response).to have_http_status(:unauthorized)

      app_attempt(email: 'nobody6@example.com')
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers).to include('RateLimit-Limit' => '5', 'RateLimit-Remaining' => '0')
      expect(response.headers['RateLimit-Reset']).to be_present
      expect(response.media_type).to eq('text/plain')
    end

    it 'counts attempts on one address from rotating IPs, read from the JSON body' do
      Prosopite.pause

      5.times { |i| app_attempt(email: 'person@example.com', ip: "10.0.0.#{i + 1}") }
      expect(response).to have_http_status(:unauthorized)

      app_attempt(email: 'person@example.com', ip: '10.0.0.99')
      expect(response).to have_http_status(:too_many_requests)

      # The control: another address from yet another IP is not throttled.
      app_attempt(email: 'someone-else@example.com', ip: '10.0.0.100')
      expect(response).to have_http_status(:unauthorized)
    end

    it 'counts the address whatever its case and outer spaces' do
      Prosopite.pause

      ['person@example.com', ' Person@Example.com', 'PERSON@EXAMPLE.COM ', 'person@EXAMPLE.com', "person@example.com\n"]
        .each_with_index { |email, i| app_attempt(email: email, ip: "10.0.1.#{i + 1}") }
      expect(response).to have_http_status(:unauthorized)

      app_attempt(email: 'person@example.com', ip: '10.0.1.99')
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'shares the per-IP bucket with the web: 3 attempts there and 3 through the door give 429' do
      Prosopite.pause

      3.times { |i| web_attempt(email: "web#{i}@example.com") }
      2.times { |i| app_attempt(email: "app#{i}@example.com") }
      expect(response).to have_http_status(:unauthorized)

      app_attempt(email: 'app2@example.com')
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'shares the per-address bucket with the web, from rotating IPs and in both orders' do
      Prosopite.pause

      3.times { |i| web_attempt(email: 'person@example.com', ip: "10.0.2.#{i + 1}") }
      2.times { |i| app_attempt(email: 'person@example.com', ip: "10.0.2.#{i + 10}") }
      expect(response).to have_http_status(:unauthorized)
      app_attempt(email: 'person@example.com', ip: '10.0.2.99')
      expect(response).to have_http_status(:too_many_requests)

      3.times { |i| app_attempt(email: 'other@example.com', ip: "10.0.3.#{i + 1}") }
      2.times { |i| web_attempt(email: 'other@example.com', ip: "10.0.3.#{i + 10}") }
      expect(response).not_to have_http_status(:too_many_requests)
      web_attempt(email: 'other@example.com', ip: '10.0.3.99')
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with doubled slashes' do
      Prosopite.pause

      5.times { |i| app_attempt(email: "nobody#{i}@example.com", path: '//api/auth/v1//app_sessions') }
      expect(response).to have_http_status(:unauthorized)

      app_attempt(email: 'nobody6@example.com', path: '//api/auth/v1//app_sessions/')
      expect(response).to have_http_status(:too_many_requests)
    end

    # The door has no address with a format (404), and the brake counts such a
    # request all the same: it never becomes a free guess if the route changes.
    it 'counts a .json suffix, which is no sign-in' do
      Prosopite.pause

      5.times { app_attempt(path: "#{app_path}.json") }
      expect(response).to have_http_status(:not_found)

      app_attempt
      expect(response).to have_http_status(:too_many_requests)
    end

    # The door reads its body and nothing else. An address in the query string
    # must not pick the bucket for an attempt on the address in the body.
    it 'reads the address from the body, never from the query string' do
      Prosopite.pause

      5.times do |i|
        app_attempt(email: 'person@example.com', ip: "10.0.4.#{i + 1}",
                    path: "#{app_path}?user[email]=decoy#{i}@example.com")
      end
      expect(response).to have_http_status(:unauthorized)

      app_attempt(email: 'person@example.com', ip: '10.0.4.99', path: "#{app_path}?user[email]=decoy9@example.com")
      expect(response).to have_http_status(:too_many_requests)
    end

    # An address of bytes that are no UTF-8 used to raise in the brake itself
    # (String#downcase), a 500 out of the middleware, on the web sign-in as well.
    # It names no account, so it picks no bucket of an address. The door refuses
    # such a body before the brake sees it.
    it 'reads bytes that are no UTF-8 as no address and never raises' do
      Prosopite.pause
      broken = { user: { email: 'person@example.com', password: 'wrong-password' }, device: { name: 'iPhone' } }
               .to_json.b.sub('person'.b, "per\xFFson".b)

      post app_path, params: broken, headers: json_headers
      expect(response).to have_http_status(:bad_request)

      post user_session_path, params: 'user[email]=per%FFson@example.com&user[password]=wrong-password',
                              headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded', 'REMOTE_ADDR' => '10.0.5.1' }
      expect(response.status).to be < 500
      expect(response).not_to have_http_status(:too_many_requests)

      # The control: an address that can be read is counted on both.
      5.times { |i| app_attempt(email: 'person@example.com', ip: "10.0.5.#{i + 10}") }
      web_attempt(email: 'person@example.com', ip: '10.0.5.99')
      expect(response).to have_http_status(:too_many_requests)
    end

    # Rails reads three more content types as JSON (synonyms of its Mime type) and
    # parses them; Rack reads the header as sent, and the brake found no address
    # in such a request. The door takes application/json only, so under these
    # types nobody is looked up; the per-IP bucket counts the request all the same.
    %w[text/x-json application/jsonrequest application/problem+json].each do |type|
      it "reaches no account under the content type #{type}, which only Rails reads as JSON" do
        Prosopite.pause
        account = create(:user, email: 'person@example.com', password: 'password123')
        body = { user: { email: 'person@example.com', password: 'wrong-password' }, device: { name: 'iPhone' } }.to_json

        8.times { |i| post app_path, params: body, headers: { 'CONTENT_TYPE' => type, 'REMOTE_ADDR' => "10.0.6.#{i + 1}" } }
        expect(response).to have_http_status(:unsupported_media_type)
        expect(account.reload.failed_attempts).to eq(0)

        6.times { post app_path, params: body, headers: { 'CONTENT_TYPE' => type, 'REMOTE_ADDR' => '10.0.6.99' } }
        expect(response).to have_http_status(:too_many_requests)

        # The control: the same body as application/json is an attempt on the account.
        app_attempt(email: 'person@example.com', ip: '10.0.6.100')
        expect(response).to have_http_status(:unauthorized)
        expect(account.reload.failed_attempts).to eq(1)
      end

      # Should such a body ever reach the brake again, it reads the address of this
      # path whatever the type says: the door and the brake cannot drift apart.
      it "reads the address of the app sign-in under #{type} in the brake itself" do
        body = { user: { email: ' Person@Example.com' }, device: { name: 'iPhone' } }.to_json
        request = lambda do |path, content_type|
          Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: 'POST', input: body,
                                                                    'CONTENT_TYPE' => content_type))
        end

        expect(Rack::Attack.login_email(request.call(app_path, type))).to eq('person@example.com')
        # The control: on the web sign-in the type decides, as before.
        expect(Rack::Attack.login_email(request.call('/users/sign_in', type))).to be_nil
        expect(Rack::Attack.login_email(request.call('/users/sign_in', 'application/json'))).to eq('person@example.com')
      end
    end

    it 'does not count a GET on the methods, which is no attempt' do
      Prosopite.pause

      10.times { get '/api/auth/v1/methods' }
      expect(response).to have_http_status(:ok)

      app_attempt
      expect(response).to have_http_status(:unauthorized)
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

  # The unlock form mails an arbitrary address on request, like the reset and
  # the confirmation resend. It had no limit of its own until 2026-11-15: only
  # the global 300 per 5 minutes stood between it and a mail cannon, and before
  # config.paranoid it also answered "not found" as fast as one could ask.
  describe 'unlock (unlocks/ip, 3 per minute)' do
    let(:params) { { user: { email: 'nobody@example.com' } } }

    it 'lets the allowance through and throttles the next request' do
      Prosopite.pause

      Rack::Attack::CONFIRMATIONS_LIMIT.times { post user_unlock_path, params: params }
      expect(response).not_to have_http_status(:too_many_requests)

      post user_unlock_path, params: params
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a format suffix or padded slashes' do
      Prosopite.pause

      post user_unlock_path(format: :html), params: params
      post '/users/unlock/', params: params
      post '//users/unlock', params: params
      post user_unlock_path(format: :html), params: params

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

  # The sign-up form says when an address already has an account, and it has to:
  # a new account is signed in at once (the grace period), which an address that
  # is taken can never be, so the two answers cannot look alike. What it must not
  # be is a cheap way to run a list of addresses against the instance. Until
  # 2026-11-15 only registrations/ip stood in the way: 20 answers an hour, 480 a
  # day, and with a password too short on purpose none of them wrote anything.
  # Signups::TakenAddressBrake closes the sign-up for an address that collected
  # five such answers in a day.
  describe 'sign-up answers "address taken" (signup_taken/ip, 5 per day)' do
    let!(:known) { create(:user, email: 'known@example.com') }
    let(:taken_message) { CGI.escapeHTML(known.errors.generate_message(:email, :taken)) }

    before { Prosopite.pause }

    # The password is too short on purpose: this is the probe that costs nothing,
    # the form names both errors and no account is created for an unknown address.
    def probe(email, ip: '203.0.113.9')
      post user_registration_path,
           params: { user: { first_name: 'Otto', last_name: 'Neuling', email: email,
                             password: 'x', password_confirmation: 'x',
                             terms_accepted: '1' } }.merge(bot_trap_params),
           headers: { 'REMOTE_ADDR' => ip }
    end

    def collect_the_allowance(ip: '203.0.113.9')
      Signups::TakenAddressBrake::LIMIT.times do
        probe(known.email, ip: ip)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(taken_message)
      end
    end

    it 'closes the sign-up after the fifth such answer, whatever address comes next' do
      collect_the_allowance

      probe('fresh@example.com')
      expect(response).to have_http_status(:too_many_requests)
    end

    # Otherwise this would be a second registrations/ip with a lower number, and
    # a person who mistypes their password five times would be locked out.
    it 'does not count a refusal that says nothing about an address' do
      (Signups::TakenAddressBrake::LIMIT + 1).times do |index|
        probe("nobody#{index}@example.com")
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to include(taken_message)
      end
    end

    it 'leaves another address alone' do
      collect_the_allowance

      probe(known.email, ip: '198.51.100.9')
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'opens again after a day' do
      collect_the_allowance
      probe(known.email)
      expect(response).to have_http_status(:too_many_requests)

      travel(Signups::TakenAddressBrake::PERIOD + 1.second)

      probe(known.email)
      expect(response).to have_http_status(:unprocessable_content)
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
  # A throttle discriminator is part of the cache key, and the file store production
  # runs on writes that key into a file name. The database only ever holds a token's
  # digest; a raw token as the discriminator put the plaintext of every active token on
  # disk, in tmp/cache and in whatever backs that up.
  describe 'token throttles (api_v1/token, api_mcp/token, 60 per minute)' do
    let(:token) { "#{PersonalAccessToken::TOKEN_PREFIX}#{'x' * PersonalAccessToken::TOKEN_BODY_LENGTH}" }
    let(:other_token) { "#{PersonalAccessToken::TOKEN_PREFIX}#{'y' * PersonalAccessToken::TOKEN_BODY_LENGTH}" }

    def bearer(raw, ip)
      { 'Authorization' => "Bearer #{raw}", 'REMOTE_ADDR' => ip }
    end

    def call_api_v1(raw, ip: '203.0.113.1')
      get '/api/v1/me', headers: bearer(raw, ip)
    end

    def call_mcp(raw, ip: '203.0.113.1')
      post '/api/mcp', headers: bearer(raw, ip)
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @cache_dir = dir
        Rack::Attack.cache.store = ActiveSupport::Cache::FileStore.new(dir)
        example.run
      end
    end

    before { Prosopite.pause }

    def cache_file_names
      Dir.glob(File.join(@cache_dir, '**', '*')).select { |path| File.file?(path) }
    end

    %i[call_api_v1 call_mcp].each do |call|
      it "keeps the plaintext out of the cache (#{call})" do
        send(call, token)

        expect(cache_file_names).not_to be_empty
        expect(cache_file_names.join).not_to include(token)
        expect(cache_file_names.map { |path| File.binread(path) }.join).not_to include(token)
      end

      # Each call from its own address, so that only the token bucket can answer 429.
      it "counts one token across addresses (#{call})" do
        60.times { |i| send(call, token, ip: "203.0.113.#{i + 1}") }
        expect(response).not_to have_http_status(:too_many_requests)

        send(call, token, ip: '198.51.100.1')
        expect(response).to have_http_status(:too_many_requests)
      end

      it "gives another token its own bucket (#{call})" do
        60.times { |i| send(call, token, ip: "203.0.113.#{i + 1}") }

        send(call, other_token, ip: '198.51.100.1')
        expect(response).not_to have_http_status(:too_many_requests)
      end
    end
  end

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
