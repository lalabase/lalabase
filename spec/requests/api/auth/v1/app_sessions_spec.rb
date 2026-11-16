# frozen_string_literal: true

require 'rails_helper'

# What: POST /api/auth/v1/app_sessions, the sign-in of a client. An e-mail address, a
#   password and a device name give an access token of kind app_session, once.
# Why: the door stands in front of every account without a session and without a token.
#   It must never tell more than the web sign-in does: an unknown address, a wrong
#   password and a locked account read the same, and what state an account is in learns
#   only who sends its right password. Every refusal below has its success in the same
#   block, so a door that refuses everybody cannot pass.
RSpec.describe 'App sign-in (POST /api/auth/v1/app_sessions)', :ci_guard, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:path) { '/api/auth/v1/app_sessions' }
  let(:password) { 'password123' }
  let(:organisation) { create(:organisation) }
  let(:user) do
    create(:user, email: 'person@example.com', password: password, first_name: 'Beispiel', last_name: 'Person',
                  language_preference: 'de')
  end
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation),
                          active: true)
    end
  end

  def json_headers(extra = {})
    { 'CONTENT_TYPE' => 'application/json' }.merge(extra)
  end

  def body_for(email: 'person@example.com', password: 'password123', device: 'iPhone')
    { user: { email: email, password: password }, device: { name: device } }
  end

  def sign_in_with(headers: {}, **fields)
    post path, params: body_for(**fields).to_json, headers: json_headers(headers)
  end

  def post_raw(raw, headers: {})
    post path, params: raw, headers: json_headers(headers)
  end

  def json
    response.parsed_body
  end

  def device_tokens
    PersonalAccessToken.app_sessions.where(user: user)
  end

  # Status and body of an answer, what a caller can compare.
  def answer
    [response.status, response.body]
  end

  # Runs the block with the application log at `level` and answers what was written.
  def logging(level: :debug)
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = level
    level_was = Rails.logger.level
    Rails.logger.level = level
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
    Rails.logger.level = level_was
  end

  def expect_signed_in
    expect(response).to have_http_status(:created)
    expect(json.dig('data', 'token')).to start_with(PersonalAccessToken::TOKEN_PREFIX)
  end

  def expect_invalid_credentials(message: I18n.t('devise.failure.invalid', locale: :de, authentication_keys: 'E-Mail'))
    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq('error' => 'unauthorized', 'code' => 'unauthorized', 'reason' => 'invalid_credentials',
                       'message' => message)
  end

  describe 'a sign-in' do
    it 'answers 201 with the token once, the session and the user' do
      freeze_time do
        sign_in_with

        expect(response).to have_http_status(:created)
        token = device_tokens.sole
        expect(json.keys).to eq(['data'])
        expect(json['data'].keys).to contain_exactly('token', 'session', 'user')
        expect(json.dig('data', 'token')).to match(/\A#{PersonalAccessToken::TOKEN_PREFIX}[A-Za-z0-9]{32}\z/o)
        expect(PersonalAccessToken.authenticate(json.dig('data', 'token'))).to eq(token)
        expect(json.dig('data', 'session')).to eq(
          'id' => token.id, 'kind' => 'app_session', 'name' => 'iPhone', 'prefix' => token.token_prefix,
          'read_only' => false, 'all_organisations' => true,
          'expires_at' => PersonalAccessToken::MAX_LIFETIME.from_now.iso8601,
          'ends_at' => PersonalAccessToken::APP_SESSION_MAX_AGE.from_now.iso8601
        )
        expect(json.dig('data', 'user')).to eq('id' => user.id, 'email' => 'person@example.com',
                                               'display_name' => user.display_name)
      end
    end

    it 'forbids every cache to keep the answer, a refusal included' do
      sign_in_with
      expect(response.headers['Cache-Control']).to eq('no-store')

      sign_in_with(password: 'wrong-password')
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['Cache-Control']).to eq('no-store')
    end

    it 'hands out a token that opens /api/v1/me, with the capability app_sessions' do
      sign_in_with
      token = json.dig('data', 'token')

      get '/api/v1/me', headers: { 'Authorization' => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(json.dig('data', 'user', 'email')).to eq('person@example.com')
      expect(json.dig('data', 'token')).to include('kind' => 'app_session', 'name' => 'iPhone', 'read_only' => false)
      expect(json.dig('data', 'capabilities')).to include('app_sessions')
      expect(json.dig('data', 'scoped_organisations').pluck('id')).to eq([organisation.id])
    end

    it 'makes a new token for every sign-in, each with its own secret' do
      sign_in_with(device: 'iPhone')
      first = json.dig('data', 'token')
      sign_in_with(device: 'iPad')
      second = json.dig('data', 'token')

      expect(first).not_to eq(second)
      expect(device_tokens.order(:created_at).pluck(:name)).to eq(%w[iPhone iPad])
    end

    it 'finds the address whatever its case and outer spaces, like the web form' do
      sign_in_with(email: '  Person@Example.COM ')
      expect_signed_in

      # The control: another address does not sign this account in.
      sign_in_with(email: 'person2@example.com')
      expect_invalid_credentials
    end

    it 'keeps the device name as sent, without outer spaces' do
      sign_in_with(device: "  Annas   iPhone 15 \n")

      expect_signed_in
      expect(json.dig('data', 'session', 'name')).to eq('Annas iPhone 15')
    end
  end

  # The requests that never reach an account.
  describe 'a request the door cannot read' do
    it 'answers 400 for a body that is no JSON, without the text of the exception' do
      post_raw('{"user": {"email": "person@example.com", "password": "password123"')

      expect(response).to have_http_status(:bad_request)
      expect(json).to eq('error' => 'bad_request', 'code' => 'invalid_input')
      expect(response.body).not_to include('password123', 'person@example.com', 'unexpected', 'Error occurred')
      expect(device_tokens).to be_empty

      sign_in_with
      expect_signed_in
    end

    it 'answers 415 for anything but application/json and reads no credentials from it' do
      {
        'a form' => [body_for, {}],
        'plain text' => [body_for.to_json, { 'CONTENT_TYPE' => 'text/plain' }],
        'a JSON relative' => [body_for.to_json, { 'CONTENT_TYPE' => 'application/vnd.api+json' }],
        # Rails reads these three as JSON (synonyms of its Mime type) and parses them;
        # the per-address brake reads the header as sent and found no address in them.
        'text/x-json' => [body_for.to_json, { 'CONTENT_TYPE' => 'text/x-json' }],
        'application/jsonrequest' => [body_for.to_json, { 'CONTENT_TYPE' => 'application/jsonrequest' }],
        'application/problem+json' => [body_for(password: 'wrong-password').to_json,
                                       { 'CONTENT_TYPE' => 'application/problem+json' }]
      }.each do |name, (params, headers)|
        post path, params: params, headers: headers

        expect(response).to have_http_status(:unsupported_media_type), name
        expect(json).to eq('error' => 'unsupported_media_type', 'code' => 'invalid_input',
                           'message' => I18n.t('services.app_sessions.unsupported_media_type', locale: :de)), name
      end
      expect(device_tokens).to be_empty
      expect(user.reload.failed_attempts).to eq(0)

      # The control: the same fields as JSON, with a charset parameter.
      post path, params: body_for.to_json, headers: { 'CONTENT_TYPE' => 'application/json; charset=utf-8' }
      expect_signed_in
    end

    it 'answers 413 for a body over 4 KB' do
      sign_in_with(device: 'x' * 4096)

      expect(response).to have_http_status(:content_too_large)
      expect(json).to eq('error' => 'body_too_large', 'code' => 'invalid_input')
      expect(device_tokens).to be_empty

      sign_in_with
      expect_signed_in
    end

    # Raw bytes that are no UTF-8 never reach the parser: the middleware in front of
    # it refuses them. Rails itself answered them with a page of its own and wrote
    # "Invalid encoding for parameter: <the value>" into the log at the level of
    # production, the password with it; before that the per-address brake raised on
    # such an address, a 500.
    {
      'the address' => ['person@example.com', "per\xFFson@example.com"],
      'the password' => ['password123', "pass\xFFword123"],
      'the device name' => ['iPhone', "iPh\xFFone"]
    }.each do |name, (text, broken)|
      it "answers 400 for bytes that are no UTF-8 in #{name}, never 500, and counts nothing" do
        post_raw(body_for.to_json.b.sub(text.b, broken.b))

        expect(response).to have_http_status(:bad_request)
        expect(json).to eq('error' => 'bad_request', 'code' => 'invalid_input')
        expect(device_tokens).to be_empty
        expect(user.reload.failed_attempts).to eq(0)
        expect(UserActivity.count).to eq(0)

        sign_in_with
        expect_signed_in
      end
    end

    it 'answers 404 for the address with a format, and for another verb' do
      post "#{path}.json", params: body_for.to_json, headers: json_headers
      expect(response).to have_http_status(:not_found)

      get path
      expect(response).to have_http_status(:not_found)
      expect(device_tokens).to be_empty

      sign_in_with
      expect_signed_in
    end
  end

  describe 'fields (422, never 500)' do
    def expect_refused_fields(*keys)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json).to eq('error' => 'validation_failed', 'code' => 'invalid_input',
                         'errors' => keys.map { |key| I18n.t("services.app_sessions.#{key}", locale: :de, count: 255) })
    end

    after do
      expect(device_tokens).to be_empty
      expect(user.reload.failed_attempts).to eq(0)

      # The control of every example here: the same door signs in what is well-formed.
      sign_in_with
      expect_signed_in
    end

    it 'names every missing field' do
      post_raw('{}')
      expect_refused_fields(:email_missing, :password_missing, :device_name_blank)
    end

    it 'refuses an empty address, an empty password and an empty device name' do
      sign_in_with(email: ' ', password: '', device: " \n ")
      expect_refused_fields(:email_missing, :password_missing, :device_name_blank)
    end

    it 'refuses a device name over 255 characters and takes one of 255' do
      sign_in_with(device: 'x' * 256)
      expect_refused_fields(:device_name_too_long)
      expect(json['errors'].first).to include('255')

      sign_in_with(device: 'x' * 255)
      expect_signed_in
      device_tokens.delete_all
    end

    # The shape of a field belongs to the caller. A list or a hash where a text
    # belongs used to be the classic way into a 500.
    {
      'the address as a list' => { user: { email: ['person@example.com'], password: 'password123' }, device: { name: 'iPhone' } },
      'the address as a hash' => { user: { email: { a: 'person@example.com' }, password: 'password123' }, device: { name: 'iPhone' } },
      'the address as a number' => { user: { email: 5, password: 'password123' }, device: { name: 'iPhone' } }
    }.each do |name, body|
      it "reads #{name} as a missing address" do
        post_raw(body.to_json)
        expect_refused_fields(:email_missing)
      end
    end

    {
      'the password as a list' => { user: { email: 'person@example.com', password: ['password123'] }, device: { name: 'iPhone' } },
      'the password as a hash' => { user: { email: 'person@example.com', password: { a: 'password123' } }, device: { name: 'iPhone' } },
      'the password as a number' => { user: { email: 'person@example.com', password: 123_456 }, device: { name: 'iPhone' } }
    }.each do |name, body|
      it "reads #{name} as a missing password" do
        post_raw(body.to_json)
        expect_refused_fields(:password_missing)
      end
    end

    {
      'the device as a text' => { user: { email: 'person@example.com', password: 'password123' }, device: 'iPhone' },
      'the device name as a list' => { user: { email: 'person@example.com', password: 'password123' }, device: { name: ['iPhone'] } },
      'the device name as a hash' => { user: { email: 'person@example.com', password: 'password123' }, device: { name: { a: 'iPhone' } } },
      'no device at all' => { user: { email: 'person@example.com', password: 'password123' } }
    }.each do |name, body|
      it "reads #{name} as a missing device name" do
        post_raw(body.to_json)
        expect_refused_fields(:device_name_blank)
      end
    end

    {
      'the user as a text' => { user: 'person@example.com', device: { name: 'iPhone' } },
      'the user as a list' => { user: ['person@example.com', 'password123'], device: { name: 'iPhone' } },
      'a list as the body' => [body_for_list = { user: { email: 'person@example.com', password: 'password123' } }, body_for_list],
      'a text as the body' => 'person@example.com',
      'null as the body' => nil
    }.each do |name, body|
      it "reads #{name} as missing fields" do
        post_raw(body.to_json)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json['errors']).to include(I18n.t('services.app_sessions.email_missing', locale: :de),
                                          I18n.t('services.app_sessions.password_missing', locale: :de))
      end
    end

    # Neither PostgreSQL nor the password hash takes a NUL byte; each raised into a
    # 500 before the door read such a text as missing.
    {
      'the address' => [{ email: "person\u0000@example.com" }, :email_missing],
      'the password' => [{ password: "password123\u0000" }, :password_missing],
      'the device name' => [{ device: "iPh\u0000one" }, :device_name_blank]
    }.each do |name, (fields, key)|
      it "reads a NUL byte in #{name} as a missing field" do
        sign_in_with(**fields)
        expect_refused_fields(key)
      end
    end

    it 'refuses a NUL byte for an unknown address the same way' do
      sign_in_with(email: 'nobody@example.com', password: "pass\u0000word")
      expect_refused_fields(:password_missing)
    end

    it 'reads the body only: fields in the query string are no fields' do
      post "#{path}?user[email]=person@example.com&user[password]=password123&device[name]=iPhone",
           params: '{}', headers: json_headers
      expect_refused_fields(:email_missing, :password_missing, :device_name_blank)
    end
  end

  # Nobody learns from this door whether an address has an account,
  # or that an account is locked.
  describe 'what the door tells about an account' do
    it 'answers an unknown address and a wrong password alike: status, body and language' do
      user.update!(language_preference: 'en')

      sign_in_with(email: 'nobody@example.com')
      unknown = answer
      expect_invalid_credentials

      sign_in_with(password: 'wrong-password')
      expect(answer).to eq(unknown)

      sign_in_with
      expect_signed_in
    end

    it 'answers in the language of the request, never in the language of the account' do
      user.update!(language_preference: 'en')

      sign_in_with(password: 'wrong-password')
      expect(json['message']).to eq('Ungültige E-Mail oder Passwort.')

      sign_in_with(password: 'wrong-password', headers: { 'Accept-Language' => 'en-GB,en;q=0.9,de;q=0.5' })
      expect(json['message']).to eq('Invalid email or password.')
      sign_in_with(email: 'nobody@example.com', headers: { 'Accept-Language' => 'en-GB,en;q=0.9,de;q=0.5' })
      expect(json['message']).to eq('Invalid email or password.')

      user.update!(language_preference: 'de')
      sign_in_with(password: 'wrong-password', headers: { 'Accept-Language' => 'en' })
      expect(json['message']).to eq('Invalid email or password.')
    end

    # The same reading as the pages with a session (ApplicationController#browser_locale).
    {
      nil => 'Das Passwort fehlt.',
      'de' => 'Das Passwort fehlt.',
      'en' => 'The password is missing.',
      'fr, en;q=0.8, de;q=0.3' => 'The password is missing.',
      'en;q=0.2, de;q=0.9' => 'Das Passwort fehlt.',
      'en;q=0, de;q=0.1' => 'Das Passwort fehlt.',
      'fr-CH, it' => 'Das Passwort fehlt.',
      'en;q=nonsense' => 'Das Passwort fehlt.'
    }.each do |header, text|
      it "words a refused field for Accept-Language #{header.inspect}" do
        sign_in_with(password: '', headers: header ? { 'Accept-Language' => header } : {})

        expect(json['errors']).to eq([text])
      end
    end

    it 'leaves the language of the thread as it was' do
      I18n.with_locale(:de) do
        sign_in_with(password: 'wrong-password', headers: { 'Accept-Language' => 'en' })
        expect(json['message']).to eq('Invalid email or password.')
        expect(I18n.locale).to eq(:de)
      end
    end

    # The activity log notes the address and the User-Agent of an attempt on a known
    # account, and of nobody else. A header that made that note raise turned into an
    # answer only a known address gave. The level is the one of production: below it
    # the request log reads the address of every caller itself.
    {
      'a User-Agent of bytes that are no UTF-8' => { 'User-Agent' => "App\xFF/1.0" },
      'a User-Agent with a NUL byte' => { 'User-Agent' => "App\u0000/1.0" },
      'a Client-IP that contradicts X-Forwarded-For' => { 'Client-IP' => '198.51.100.1',
                                                          'X-Forwarded-For' => '198.51.100.2' }
    }.each do |name, headers|
      it "answers a known and an unknown address alike with #{name}, and still notes the attempt" do
        logging(level: :warn) do
          sign_in_with(email: 'nobody@example.com', headers: headers)
          unknown = answer
          expect_invalid_credentials

          sign_in_with(password: 'wrong-password', headers: headers)
          expect(answer).to eq(unknown)
          expect(UserActivity.where(user: user, action: 'login_failed').count).to eq(1)

          # The right password signs in under the same headers, and the login is noted.
          sign_in_with(headers: headers)
          expect_signed_in
          expect(UserActivity.where(user: user, action: 'login').count).to eq(1)
        end
      end
    end

    # The password is checked on the row as it was read. A new password revokes every
    # token of the account once, at the change: a sign-in that passed the check just
    # before must not write its token just after.
    it 'hands out no token when the password changed between the check and the write' do
      sign_in_with(email: 'nobody@example.com')
      unknown = answer

      allow(AppSessions::Authentication).to receive(:call).and_wrap_original do |original, **arguments|
        original.call(**arguments).tap do |attempt|
          next unless attempt.success?

          User.find(attempt.user.id).update!(password: 'a-new-password-1', password_confirmation: 'a-new-password-1')
        end
      end
      sign_in_with
      expect(answer).to eq(unknown)
      expect(device_tokens.active).to be_empty

      RSpec::Mocks.space.reset_all
      sign_in_with(password: 'a-new-password-1')
      expect_signed_in
    end

    it 'never names a lock or a last attempt' do
      Prosopite.pause { 25.times { sign_in_with(password: 'wrong-password') } }

      expect(user.reload).to be_access_locked
      expect(response.body).not_to match(/lock|gesperrt|last_attempt|Versuch/i)
      expect_invalid_credentials
    ensure
      Prosopite.resume
    end
  end

  # Failed attempts through the door count like those on
  # the web, and the lock holds against the right password too.
  describe 'the counter and the lock' do
    def fail_times(count)
      Prosopite.pause { count.times { sign_in_with(password: 'wrong-password') } }
    ensure
      Prosopite.resume
    end

    it 'counts every failed attempt and locks at the twentieth' do
      expect(Devise.maximum_attempts).to eq(20)

      fail_times(19)
      expect(user.reload).to have_attributes(failed_attempts: 19, locked_at: nil)

      # The mail with the unlock link is how the person learns about the lock.
      with_test_queue_adapter do
        expect { fail_times(1) }.to have_enqueued_mail(Devise::Mailer, :unlock_instructions)
      end
      expect(user.reload.failed_attempts).to eq(20)
      expect(user).to be_access_locked
    end

    it 'answers a locked account like a wrong password, with the wrong AND with the right one, and counts on' do
      sign_in_with(email: 'nobody@example.com')
      unknown = answer
      fail_times(20)
      expect(user.reload).to be_access_locked

      sign_in_with(password: 'wrong-password')
      expect(answer).to eq(unknown)
      expect(user.reload.failed_attempts).to eq(21)

      sign_in_with
      expect(answer).to eq(unknown)
      expect(response.body).not_to include(PersonalAccessToken::TOKEN_PREFIX)
      expect(user.reload.failed_attempts).to eq(22)
      expect(device_tokens).to be_empty
    end

    it 'signs in with the right password once the lock has run out' do
      fail_times(20)
      sign_in_with
      expect(response).to have_http_status(:unauthorized)

      travel(Devise.unlock_in + 1.second) do
        sign_in_with

        expect_signed_in
        expect(user.reload).to have_attributes(failed_attempts: 0, locked_at: nil)
      end
    end

    it 'resets the counter with a sign-in: 19 failures, a success and 19 failures lock nobody' do
      fail_times(19)
      sign_in_with
      expect_signed_in
      expect(user.reload.failed_attempts).to eq(0)

      fail_times(19)
      expect(user.reload).to have_attributes(failed_attempts: 19, locked_at: nil)
      sign_in_with
      expect_signed_in
    end

    it 'counts nothing for an unknown address' do
      expect { sign_in_with(email: 'nobody@example.com') }.not_to(change { user.reload.failed_attempts })
      expect(UserActivity.count).to eq(0)

      expect { sign_in_with(password: 'wrong-password') }.to change { user.reload.failed_attempts }.by(1)
    end
  end

  # What state an account is in learns only who sends its right
  # password; with a wrong one every state reads as invalid_credentials.
  describe 'the states of an account' do
    def expect_refused(reason, message_key)
      expect(response).to have_http_status(:forbidden)
      expect(json).to eq('error' => 'forbidden', 'code' => 'forbidden', 'reason' => reason,
                         'message' => I18n.t(message_key, locale: :de))
      expect(device_tokens).to be_empty
    end

    it 'signs an unconfirmed account in during the first three days' do
      user.update_columns(confirmed_at: nil, created_at: (Devise.allow_unconfirmed_access_for - 1.hour).ago)

      sign_in_with
      expect_signed_in
    end

    it 'answers 403 email_unconfirmed after the three days, to the right password only' do
      user.update_columns(confirmed_at: nil, created_at: (Devise.allow_unconfirmed_access_for + 1.hour).ago)

      sign_in_with
      expect_refused('email_unconfirmed', 'devise.failure.unconfirmed')

      sign_in_with(password: 'wrong-password')
      expect_invalid_credentials

      user.update_columns(confirmed_at: Time.current)
      sign_in_with
      expect_signed_in
    end

    it 'answers 403 account_deactivated, to the right password only' do
      user.update_columns(active: false)

      sign_in_with
      expect_refused('account_deactivated', 'devise.failure.account_deactivated')

      sign_in_with(password: 'wrong-password')
      expect_invalid_credentials

      user.update_columns(active: true, failed_attempts: 0)
      sign_in_with
      expect_signed_in
    end

    it 'answers a refused state in the language of the request' do
      user.update_columns(active: false)

      sign_in_with(headers: { 'Accept-Language' => 'en' })

      expect(json['message']).to eq(I18n.t('devise.failure.account_deactivated', locale: :en))
    end

    it 'does not reset the counter for an account that may not sign in' do
      user.update_columns(active: false, failed_attempts: 3)

      sign_in_with

      expect(response).to have_http_status(:forbidden)
      expect(user.reload.failed_attempts).to eq(3)
    end

    it 'answers a deleted account like an unknown address' do
      sign_in_with(email: 'nobody@example.com')
      unknown = answer
      sign_in_with
      expect_signed_in

      user.soft_delete!

      sign_in_with
      expect(answer).to eq(unknown)
    end

    it 'answers the system account like an unknown address and counts nothing on it' do
      system_account = User.system
      sign_in_with(email: 'nobody@example.com')
      unknown = answer

      sign_in_with(email: system_account.email, password: 'whatever-password')

      expect(answer).to eq(unknown)
      expect(system_account.reload.failed_attempts).to eq(0)
      expect(UserActivity.where(user: system_account)).to be_empty
    end

    it 'signs in an account without an organisation, and /me names none' do
      loner = create(:user, email: 'loner@example.com', password: password)

      sign_in_with(email: 'loner@example.com')
      expect_signed_in

      get '/api/v1/me', headers: { 'Authorization' => "Bearer #{json.dig('data', 'token')}" }
      expect(response).to have_http_status(:ok)
      expect(json.dig('data', 'scoped_organisations')).to eq([])
      expect(json.dig('data', 'user', 'id')).to eq(loner.id)
    end

    it 'signs in a member deactivated in one organisation, and the token leaves that one out' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        create(:membership, user: user, organisation: other, role: create(:role, organisation: other), active: false)
      end

      sign_in_with
      expect_signed_in

      get '/api/v1/me', headers: { 'Authorization' => "Bearer #{json.dig('data', 'token')}" }
      expect(json.dig('data', 'scoped_organisations').pluck('id')).to eq([organisation.id])
    end

    # A reason Devise names and this door was never told about must not become a new
    # value on the wire, and never a 500.
    it 'answers a reason it does not know as invalid_credentials' do
      sign_in_with(email: 'nobody@example.com')
      unknown = answer

      allow_any_instance_of(User).to receive(:active_for_authentication?).and_return(false)
      allow_any_instance_of(User).to receive(:inactive_message).and_return(:second_factor_missing)
      sign_in_with
      expect(answer).to eq(unknown)
      expect(device_tokens).to be_empty

      RSpec::Mocks.space.reset_all
      sign_in_with
      expect_signed_in
    end
  end

  # At most ten live devices per account.
  describe 'the eleventh device' do
    it 'revokes the device unused longest, never a personal token' do
      personal = create(:personal_access_token, user: user, organisations: [organisation], last_used_at: 80.days.ago)
      devices = Array.new(10) do |index|
        create(:personal_access_token, :app_session, user: user, last_used_at: (index + 1).days.ago)
      end

      sign_in_with(device: 'Neues Gerät')

      expect_signed_in
      revoked = PersonalAccessToken.where(user: user).where.not(revoked_at: nil)
      expect(revoked).to contain_exactly(devices.last)
      expect(personal.reload).not_to be_revoked
      expect(device_tokens.active.count).to eq(PersonalAccessToken::MAX_APP_SESSIONS)
      expect(device_tokens.active.pluck(:name)).to include('Neues Gerät')
    end

    it 'revokes nothing for the tenth' do
      Array.new(9) { |index| create(:personal_access_token, :app_session, user: user, last_used_at: (index + 1).days.ago) }

      sign_in_with

      expect_signed_in
      expect(device_tokens.where.not(revoked_at: nil)).to be_empty
      expect(device_tokens.active.count).to eq(10)
    end
  end

  # The answer holds the token, so it is never remembered.
  describe 'the Idempotency-Key header' do
    it 'is not processed: no row keeps the answer, and the same key signs in twice' do
      headers = { 'Idempotency-Key' => 'a-key-sent-twice' }

      expect { sign_in_with(headers: headers) }.not_to change(McpIdempotencyKey, :count)
      first = json.dig('data', 'token')
      expect { sign_in_with(headers: headers) }.not_to change(McpIdempotencyKey, :count)
      second = json.dig('data', 'token')

      expect([first, second]).to all(start_with(PersonalAccessToken::TOKEN_PREFIX))
      expect(first).not_to eq(second)
      expect(McpIdempotencyKey.count).to eq(0)
    end

    # The control of the count above: the same store does keep a /api/v1 write.
    it 'is processed by /api/v1, with the token of the sign-in' do
      sign_in_with
      token = json.dig('data', 'token')

      expect do
        post '/api/v1/notifications/mark_all_as_read',
             headers: { 'Authorization' => "Bearer #{token}", 'Idempotency-Key' => 'a-key-sent-twice' }
      end.to change(McpIdempotencyKey, :count).by(1)
      expect(McpIdempotencyKey.pluck(:response_content).join).not_to include(token)
    end
  end

  # Neither the password nor the token reaches the log.
  describe 'the log' do
    it 'holds neither the password nor the token of a sign-in, at level debug' do
      token = nil
      log = logging do
        sign_in_with(password: password, device: 'Log-Probe-Gerät')
        token = json.dig('data', 'token')
      end

      expect_signed_in
      # The log saw the request at all, and the device name may stand in it.
      expect(log).to include('Log-Probe-Gerät', '/api/auth/v1/app_sessions')
      expect(log).not_to include(password)
      expect(log).not_to include(token)
      expect(log).not_to include(token.delete_prefix(PersonalAccessToken::TOKEN_PREFIX))
      expect(log).to include('[FILTERED]')
    end

    # Rails names the value of a parameter it cannot decode in its error line, at
    # the level of production and past the parameter filter.
    it 'holds no part of a password of bytes that are no UTF-8, at the level of production' do
      log = logging(level: :warn) { post_raw(body_for(password: 'geheim-wort-9').to_json.b.sub('-wort'.b, "\xE4wort".b)) }

      expect(response).to have_http_status(:bad_request)
      expect(log).not_to include('geheim')
      expect(log).not_to include('wort-9')

      sign_in_with
      expect_signed_in
    end

    it 'holds no password of a failed attempt either' do
      log = logging { sign_in_with(password: 'a-wrong-secret-9') }

      expect(response).to have_http_status(:unauthorized)
      expect(log).to include('/api/auth/v1/app_sessions')
      expect(log).not_to include('a-wrong-secret-9')
    end

    # Rails itself writes a body
    # it cannot parse into the log at level debug, whole. It does not at level info.
    # That is why RAILS_LOG_LEVEL=debug does not belong on a production instance.
    it 'holds a body that is no JSON at level debug, and not at level info' do
      broken = '{"user": {"email": "person@example.com", "password": "a-secret-in-a-broken-body"'

      debug_log = logging(level: :debug) { post_raw(broken) }
      expect(response).to have_http_status(:bad_request)
      expect(debug_log).to include('a-secret-in-a-broken-body')

      info_log = logging(level: :info) { post_raw(broken) }
      expect(response).to have_http_status(:bad_request)
      expect(info_log).to include('/api/auth/v1/app_sessions')
      expect(info_log).not_to include('a-secret-in-a-broken-body')
    end
  end

  describe 'the activity of the account' do
    it 'notes a login with the method app_session and the device, without a session' do
      sign_in_with(device: 'iPhone', headers: { 'User-Agent' => 'Lalabase/1.0 (iPhone; iOS 19.0)', 'REMOTE_ADDR' => '203.0.113.7' })

      expect_signed_in
      activity = UserActivity.where(user: user).sole
      expect(activity).to have_attributes(action: 'login', status: 'success', ip_address: '203.0.113.7',
                                          user_agent: 'Lalabase/1.0 (iPhone; iOS 19.0)')
      expect(activity.metadata).to include('login_method' => 'app_session', 'device_name' => 'iPhone')
    end

    # UserActivity.track! reads request.session.id. In this API-only controller that is nil for a caller
    # without a cookie: nothing raises, no session is made and no cookie is set.
    it 'reads request.session.id in an API-only controller without making a session' do
      sign_in_with

      expect_signed_in
      expect(UserActivity.where(user: user).sole.session_id).to be_blank
      expect(response.headers['Set-Cookie']).to be_blank
    end

    it 'stores at most 255 characters of a User-Agent' do
      sign_in_with(password: 'wrong-password', headers: { 'User-Agent' => "Lalabase/#{'9' * 3000}" })

      expect(UserActivity.where(user: user).sole.user_agent).to eq("Lalabase/#{'9' * 246}")
    end

    it 'notes a failed login for a known account, and nothing for an unknown address' do
      sign_in_with(password: 'wrong-password', headers: { 'REMOTE_ADDR' => '203.0.113.7' })

      activity = UserActivity.where(user: user).sole
      expect(activity).to have_attributes(action: 'login_failed', status: 'failed', ip_address: '203.0.113.7')

      expect { sign_in_with(email: 'nobody@example.com') }.not_to change(UserActivity, :count)
    end

    it 'notes a failed login when the right password meets an account that may not sign in' do
      user.update_columns(active: false)

      sign_in_with

      expect(UserActivity.where(user: user).sole).to have_attributes(action: 'login_failed', status: 'failed')
    end
  end

  # Every visitor of the public demo shares one account with a
  # published password, exempt from the lock and from the per-address brake.
  describe 'the public demo' do
    around do |example|
      flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
      example.run
    ensure
      ENV[Lalabase::Demo::ENV_FLAG] = flag_was
    end

    def demo(on)
      ENV[Lalabase::Demo::ENV_FLAG] = on ? Lalabase::Demo::ENABLED_VALUE : nil
    end

    it 'answers 404 and hands out no token, also to the right password' do
      demo(true)
      sign_in_with

      expect(response).to have_http_status(:not_found)
      expect(json).to eq('error' => 'not_found', 'code' => 'not_found')
      expect(device_tokens).to be_empty

      demo(false)
      sign_in_with
      expect_signed_in
    end

    it 'answers 404 whatever the body is' do
      demo(true)

      post_raw('{"user": ')
      expect(response).to have_http_status(:not_found)
      sign_in_with(device: 'x' * 5000)
      expect(response).to have_http_status(:not_found)
      expect(json).to eq('error' => 'not_found', 'code' => 'not_found')
      post_raw(body_for.to_json.b.sub('iPhone'.b, "iPh\xFFone".b))
      expect(response).to have_http_status(:not_found)
      post path, params: body_for
      expect(response).to have_http_status(:not_found)
      post_raw('{}')
      expect(response).to have_http_status(:not_found)

      demo(false)
      post_raw('{}')
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
