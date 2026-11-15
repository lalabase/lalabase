# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Provisioning signup throttling' do
  let(:secret) { SecureRandom.hex(32) }
  let(:configuration) { Lalabase::ProvisioningConfiguration.new(secret: secret) }

  around do |example|
    previous_enabled = Rack::Attack.enabled
    previous_store = Rack::Attack.cache.store
    previous_configuration = Rails.configuration.x.provisioning
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rails.configuration.x.provisioning = configuration
    example.run
  ensure
    Rack::Attack.cache.store = previous_store
    Rack::Attack.enabled = previous_enabled
    Rails.configuration.x.provisioning = previous_configuration
  end

  # Deliberately empty: the throttle runs in front of the controller, so a
  # request that never reaches a valid body still counts against the bucket.
  def post_signup(visitor_ip:, authorization: "Bearer #{secret}")
    post '/api/provisioning/v1/signups',
         params: {}.to_json,
         headers: { 'Authorization' => authorization,
                    'X-Lalabase-Visitor-IP' => visitor_ip,
                    'CONTENT_TYPE' => 'application/json',
                    'REMOTE_ADDR' => '127.0.0.1' }
  end

  it 'counts per visitor, so one visitor cannot use up the funnel' do
    Rack::Attack::REGISTRATIONS_LIMIT.times do
      post_signup(visitor_ip: '203.0.113.7')
      expect(response).to have_http_status(:bad_request)
    end

    post_signup(visitor_ip: '203.0.113.7')
    expect(response).to have_http_status(:too_many_requests)

    post_signup(visitor_ip: '198.51.100.7')
    expect(response).to have_http_status(:bad_request)
  end

  it 'does not lump every visitor into the website server bucket' do
    (Rack::Attack::REGISTRATIONS_LIMIT + 1).times do |index|
      post_signup(visitor_ip: "203.0.#{index}.7")
      expect(response).to have_http_status(:bad_request)
    end
  end

  # Without this the claim would be free: an anonymous caller could invent a
  # visitor per request and never meet a limit.
  it 'ignores a visitor claimed without a valid secret and counts the caller instead' do
    Rack::Attack::REGISTRATIONS_LIMIT.times do |index|
      post_signup(visitor_ip: "203.0.#{index}.7", authorization: 'Bearer wrong')
      expect(response).to have_http_status(:unauthorized)
    end

    post_signup(visitor_ip: '203.0.113.250', authorization: 'Bearer wrong')
    expect(response).to have_http_status(:too_many_requests)
  end

  # The website shows the visitor what the core answered, "address taken"
  # included, so the brake of the sign-up form (Signups::TakenAddressBrake) has
  # to stand at this door as well, on the visitor and never on the website.
  describe 'answers that say an address is taken' do
    include ActiveSupport::Testing::TimeHelpers

    let!(:known) { create(:user, email: 'known@example.com') }

    # One window of the counter, whenever the suite runs.
    around { |example| travel_to(Time.current) { example.run } }

    # The same request several times over is a loop, not an N+1 inside a request.
    # In a before, not in the around: the global Prosopite.scan runs after an
    # around's setup and would undo the pause.
    before { Prosopite.pause }
    after { Prosopite.resume }

    def post_taken(visitor_ip:)
      headers = { 'Authorization' => "Bearer #{secret}", 'CONTENT_TYPE' => 'application/json',
                  'REMOTE_ADDR' => '127.0.0.1' }
      headers['X-Lalabase-Visitor-IP'] = visitor_ip if visitor_ip
      signup = { email: known.email, password: 'password123', first_name: 'Otto', last_name: 'Neuling',
                 language: 'en', terms_accepted: true }
      post '/api/provisioning/v1/signups', params: { signup: signup }.to_json, headers: headers
    end

    def collect_the_allowance(visitor_ip:)
      Signups::TakenAddressBrake::LIMIT.times do
        post_taken(visitor_ip: visitor_ip)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig('error', 'code')).to eq('validation_failed')
      end
    end

    it 'closes the door for that visitor after the fifth, and for nobody else' do
      collect_the_allowance(visitor_ip: '203.0.113.7')

      post_taken(visitor_ip: '203.0.113.7')
      expect(response).to have_http_status(:too_many_requests)

      post_taken(visitor_ip: '198.51.100.7')
      expect(response).to have_http_status(:unprocessable_content)
    end

    # Counted on the caller's own address, five visitors of the public pages
    # would close the sign-up for everybody who comes through the website.
    it 'counts nothing when the website names no visitor' do
      (Signups::TakenAddressBrake::LIMIT + 1).times do
        post_taken(visitor_ip: nil)
        expect(response).to have_http_status(:unprocessable_content)
      end

      # Asked directly as well: the rule in front of this door never looks at the
      # website's address, so a count on it would show nowhere above.
      expect(Signups::TakenAddressBrake.banned?('127.0.0.1')).to be(false)
    end

    # The other half: should the website's address ever be closed out (it shares
    # its bucket with the sign-up form of the core), its calls still get through.
    it 'never closes this door on the address of the website' do
      Signups::TakenAddressBrake::LIMIT.times { Signups::TakenAddressBrake.record('127.0.0.1') }

      post_taken(visitor_ip: nil)
      expect(response).to have_http_status(:unprocessable_content)

      post_taken(visitor_ip: '198.51.100.7')
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'counts together with the sign-up form of the core' do
      collect_the_allowance(visitor_ip: '203.0.113.7')

      post user_registration_path, params: { user: { email: 'fresh@example.com' } },
                                   headers: { 'REMOTE_ADDR' => '203.0.113.7' }
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'shares the form bucket when the website names an IPv4-mapped visitor' do
      collect_the_allowance(visitor_ip: '::ffff:203.0.113.7')

      post user_registration_path, params: { user: { email: 'fresh@example.com' } },
                                   headers: { 'REMOTE_ADDR' => '203.0.113.7' }
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
