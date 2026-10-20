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
      banner = Nokogiri::HTML(response.body).at_css('[data-testid="demo-banner"]')
      expect(banner.text).to include("#{Lalabase::Demo.reset_time} UTC")
      expect(Lalabase::Demo.reset_time).to match(/\A\d{2}:00\z/)
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

  # The world is written in one language (Lalabase::Demo::LOCALE), and the pages
  # around it speak the same, whatever the visitor's browser or address asks for.
  describe 'the language' do
    def page_language = Nokogiri::HTML(response.body).at_css('html')['lang']

    it 'is the language of the world, whatever the browser asks for' do
      get new_user_session_path, headers: { 'Accept-Language' => 'de-DE,de;q=0.9' }
      expect(page_language).to eq(Lalabase::Demo::LOCALE.to_s)
    end

    it 'is the language of the world on a page that asks for another, and after it' do
      get new_user_session_path(locale: 'de')
      expect(page_language).to eq(Lalabase::Demo::LOCALE.to_s)

      get new_user_session_path
      expect(page_language).to eq(Lalabase::Demo::LOCALE.to_s)
    end

    it 'is the language of the world for a person whose profile says another' do
      user = member(email: 'profile-de@example.com', password: 'a-long-password-1', language_preference: 'de')
      sign_in_with(user.email, 'a-long-password-1')
      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(page_language).to eq(Lalabase::Demo::LOCALE.to_s)
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'follows the browser' do
        get new_user_session_path, headers: { 'Accept-Language' => 'de-DE,de;q=0.9' }
        expect(page_language).to eq('de')
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

  describe 'uploads' do
    let(:limit) { Lalabase::Demo::MAX_UPLOAD_BYTES }

    def post_blob(byte_size: 5, content_type: 'image/png')
      blob = { filename: 'shot', byte_size: byte_size, checksum: 'XUFAKrxLKna5cZ2REBfFkg==', content_type: content_type }
      post rails_direct_uploads_path, params: { blob: blob }.to_json,
                                      headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
    end

    def post_body(bytes)
      post user_session_path, params: 'x' * bytes, headers: { 'Content-Type' => 'application/octet-stream' }
    end

    before { sign_in demo_user }

    it 'takes an image or a PDF up to the limit' do
      post_blob(byte_size: limit)
      expect(response).to have_http_status(:ok)
      post_blob(content_type: 'application/pdf')
      expect(response).to have_http_status(:ok)
    end

    # SVG is an image that runs script.
    it 'refuses a larger file and any other type before the blob exists' do
      Prosopite.pause do
        expect do
          post_blob(byte_size: limit + 1)
          expect(response).to have_http_status(:unprocessable_content)
          %w[text/html image/svg+xml].each do |type|
            post_blob(content_type: type)
            expect(response).to have_http_status(:unprocessable_content)
          end
        end.not_to change(ActiveStorage::Blob, :count)
      end
    end

    # The forms that post a file themselves, and the byte channel of direct uploads.
    it 'refuses any request body above the limit, and only above it' do
      post_body(limit)
      expect(response).not_to have_http_status(:content_too_large)
      post_body(limit + 1)
      expect(response).to have_http_status(:content_too_large)
    end

    # Rack::MethodOverride parses a form body before any controller could refuse it.
    it 'refuses the body before anything parses it' do
      expect(Rails.application.middleware.first.klass).to eq(Lalabase::Demo::UploadLimit)
    end

    describe 'once the stored files reach the budget' do
      let(:file_size) { Lalabase::Demo::LARGE_BODY_BYTES + 1 }

      before do
        stub_const('Lalabase::Demo::STORAGE_BUDGET_BYTES', file_size)
        ActiveStorage::Blob.create_and_upload!(io: StringIO.new('x' * file_size), filename: 'earlier.png')
      end

      it 'takes no further file, by either way' do
        post_blob(byte_size: 1)
        expect(response).to have_http_status(:unprocessable_content)
        post_body(file_size)
        expect(response).to have_http_status(:content_too_large)
      end

      it 'still takes a form or a message' do
        post_body(Lalabase::Demo::LARGE_BODY_BYTES)
        expect(response).not_to have_http_status(:content_too_large)
      end
    end

    context 'without the flag' do
      let(:demo_on) { false }

      it 'takes what any instance takes' do
        post_blob(byte_size: limit + 1, content_type: 'text/html')
        expect(response).to have_http_status(:ok)
        post_body(limit + 1)
        expect(response).not_to have_http_status(:content_too_large)
      end
    end
  end

  describe 'the per-address throttles' do
    around do |example|
      enabled_was = Rack::Attack.enabled
      store_was = Rack::Attack.cache.store
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      travel_to(Time.current) { example.run }
      Rack::Attack.cache.store = store_was
      Rack::Attack.enabled = enabled_was
    end

    # Many requests to one handler; the repeated queries are not a page's N+1.
    def from(ip, path, count = 1, method: :post, params: nil)
      Prosopite.pause { count.times { send(method, path, params: params, headers: { 'REMOTE_ADDR' => ip }) } }
    end

    def throttled? = response.status == 429

    # One daily quota for every visitor: one of them must not spend it alone.
    describe 'on what calls a model' do
      let(:limit) { Rack::Attack::DEMO_MODEL_CALL_LIMIT }
      let(:org) { "/org/#{SecureRandom.uuid}" }
      let(:project) { "#{org}/projects/#{SecureRandom.uuid}" }
      let(:model_calls) do
        ["#{org}/assistant_chats", "#{org}/assistant_chats/c1/chatposts", "#{org}/assistant_chats/c1/chatposts/p1/regenerate",
         "#{org}/assistant_chats/c1/chatposts/p1/analysis", "#{org}/assistant_chats/c1/ticket_suggestion_runs/r1/retry",
         "#{project}/tickets/t1/create_summary", "#{project}/tickets/bulk_summary", "#{project}/meetings/m1/create_summary",
         "#{project}/meetings/m1/analyses", "#{project}/meetings/m1/ticket_suggestions/run",
         "#{project}/meetings/detect_participants", "#{org}/time_session_groups/g1/generate_customer_descriptions"]
      end

      it 'counts every one of them, per address' do
        model_calls.each do |path|
          Rack::Attack.cache.store.clear
          from('10.0.2.1', path, limit)
          expect(throttled?).to be(false), path
          from('10.0.2.1', path)
          expect(throttled?).to be(true), path
          from('10.0.2.2', path)
          expect(throttled?).to be(false), path
        end
      end

      it 'counts an analysis changed and a comment that asks the AI' do
        from('10.0.2.1', "#{project}/meetings/m1/analyses/a1", 5, method: :patch)
        from('10.0.2.1', "#{project}/tickets/t1/posts", 5, params: { ask_ai: '1' })
        expect(throttled?).to be(false)
        from('10.0.2.1', "#{org}/assistant_chats.json")
        expect(throttled?).to be(true)
      end

      # rack-test tidies a padded path before the request is made, so the padding is
      # handed to the rule as Rack would hand it.
      it 'counts a padded path like the plain one' do
        padded = Rack::Attack::Request.new(Rack::MockRequest.env_for('/', method: 'POST'))
        padded.path_info = "/#{org}//assistant_chats/c1/chatposts/"
        expect(Rack::Attack.demo_model_call?(padded)).to be(true)
      end

      it 'does not count what asks no model' do
        [["#{org}/assistant_chats/c1/references", {}], ["#{project}/tickets/t1/posts", { params: { content: 'hi' } }],
         ["#{org}/assistant_chats/c1", { method: :get }]].each do |path, options|
          Rack::Attack.cache.store.clear
          from('10.0.2.1', path, limit + 1, **options)
          expect(throttled?).to be(false), path
        end
      end

      # Everybody in the demo is the same user: a bucket per user would be one for all.
      it 'counts signed-in visitors by their address, not by the shared user' do
        sign_in demo_user
        from('10.0.2.1', "#{org}/assistant_chats/c1/chatposts", limit)
        from('10.0.2.2', "#{org}/assistant_chats/c1/chatposts")
        expect(throttled?).to be(false)
      end

      context 'without the flag' do
        let(:demo_on) { false }

        it 'counts nothing' do
          from('10.0.2.1', "#{org}/assistant_chats", limit + 1)
          expect(throttled?).to be(false)
        end
      end
    end

    describe 'on files' do
      let(:limit) { Rack::Attack::DEMO_UPLOAD_LIMIT }
      let(:file) { 'x' * (Lalabase::Demo::LARGE_BODY_BYTES + 1) }

      # A path no other throttle counts.
      let(:documents) { "/org/#{SecureRandom.uuid}/projects/#{SecureRandom.uuid}/documents" }

      it 'counts every body that carries a file, per address' do
        from('10.0.3.1', documents, limit, params: file)
        expect(throttled?).to be(false)
        from('10.0.3.1', documents, params: file)
        expect(throttled?).to be(true)
        from('10.0.3.2', documents, params: file)
        expect(throttled?).to be(false)
      end

      it 'does not count a form or a message' do
        from('10.0.3.1', documents, limit + 1, params: 'x' * Lalabase::Demo::LARGE_BODY_BYTES)
        expect(throttled?).to be(false)
      end

      context 'without the flag' do
        let(:demo_on) { false }

        it 'counts nothing' do
          from('10.0.3.1', documents, limit + 1, params: file)
          expect(throttled?).to be(false)
        end
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
