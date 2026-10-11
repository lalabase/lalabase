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
end
