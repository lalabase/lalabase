# frozen_string_literal: true

require 'rails_helper'

# What: the sign-in door of clients takes a body of at most 4 KB, and refuses a larger
#   one before anything reads it.
# Why: the per-address brake reads the address from the first 4 KB of the body
#   (Rack::Attack LOGIN_BODY_LIMIT). An address behind that part would reach no bucket,
#   so a larger body is no sign-in attempt. As for the provisioning door, a status code
#   proves nothing here, so these examples watch the JSON parser itself.
RSpec.describe 'App sign-in body limit', :ci_guard, type: :request do
  let(:path) { '/api/auth/v1/app_sessions' }
  let(:limit) { Lalabase::AuthBodyLimit::MAX_BODY_BYTES }
  let!(:user) { create(:user, email: 'person@example.com', password: 'password123') }

  def watching_the_parser
    parsed = []
    original = ActionDispatch::Request.parameter_parsers[:json]
    ActionDispatch::Request.parameter_parsers =
      ActionDispatch::Request.parameter_parsers.merge(
        json: ->(raw) { parsed << raw.bytesize and original.call(raw) }
      )
    yield parsed
  ensure
    ActionDispatch::Request.parameter_parsers =
      ActionDispatch::Request.parameter_parsers.merge(json: original)
  end

  # A sign-in padded to exactly `bytes` bytes, the address behind the padding.
  def body_of(bytes, email: 'person@example.com', password: 'password123')
    frame = { pad: '', user: { email: email, password: password }, device: { name: 'iPhone' } }
    frame[:pad] = 'x' * (bytes - frame.to_json.bytesize)
    frame.to_json.tap { |json| raise "body is #{json.bytesize} bytes" unless json.bytesize == bytes }
  end

  def post_body(body, to: path, headers: {})
    post to, params: body, headers: { 'CONTENT_TYPE' => 'application/json' }.merge(headers)
  end

  it 'is the size the per-address brake reads' do
    expect(limit).to eq(Rack::Attack::LOGIN_BODY_LIMIT)
    expect(limit).to eq(4.kilobytes)
  end

  it 'refuses a body one byte over the limit without reading it, and takes one at the limit' do
    watching_the_parser do |parsed|
      post_body(body_of(limit + 1))

      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body).to eq('error' => 'body_too_large', 'code' => 'invalid_input')
      expect(parsed).to be_empty
      expect(PersonalAccessToken.count).to eq(0)

      # The control: the watch sees a body at the limit, and that one signs in.
      post_body(body_of(limit))

      expect(response).to have_http_status(:created)
      expect(parsed).to eq([limit])
    end
  end

  # Rails routes the padded path to the same action, so a raw prefix test would
  # hand exactly this request to the parser.
  it 'is not bypassed by padding the path' do
    watching_the_parser do |parsed|
      post_body(body_of(limit + 1), to: '//api/auth/v1/app_sessions')

      expect(response).to have_http_status(:content_too_large)
      expect(parsed).to be_empty
    end
  end

  it 'refuses an oversized form body too, before anything looks for _method in it' do
    post path, params: { 'user[email]' => 'person@example.com', 'pad' => 'x' * limit }

    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body).to eq('error' => 'body_too_large', 'code' => 'invalid_input')
  end

  # Content-Length is the caller's claim. A body sent in chunks carries none that
  # counts, passes the middleware and is read whole. The brake then read only its
  # first 4 KB and found no address, so the door measures the body once more and
  # looks nobody up.
  it 'refuses a larger body that claims to be small, without an attempt on the account' do
    post_body(body_of(limit + 500, password: 'wrong-password'),
              headers: { 'CONTENT_LENGTH' => '100', 'Transfer-Encoding' => 'chunked' })

    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body).to eq('error' => 'body_too_large', 'code' => 'invalid_input')
    expect(user.reload.failed_attempts).to eq(0)

    # The control: the same wrong password in a body of honest size is an attempt.
    post_body(body_of(limit, password: 'wrong-password'))
    expect(response).to have_http_status(:unauthorized)
    expect(user.reload.failed_attempts).to eq(1)
  end

  describe 'its place in the middleware stack' do
    def stack
      Rails.application.middleware.map(&:name)
    end

    it 'runs before anything that reads a body, beside the provisioning limit' do
      expect(stack.index('Lalabase::AuthBodyLimit')).to be < stack.index('Rack::MethodOverride')
      expect(stack.index('Lalabase::ProvisioningBodyLimit')).to be < stack.index('Rack::MethodOverride')
    end
  end

  # Two doors, two limits: the provisioning door keeps its 16 KB and its envelope.
  describe 'the provisioning door beside it' do
    let(:secret) { SecureRandom.hex(32) }

    around do |example|
      previous = Rails.configuration.x.provisioning
      Rails.configuration.x.provisioning = Lalabase::ProvisioningConfiguration.new(secret: secret)
      example.run
    ensure
      Rails.configuration.x.provisioning = previous
    end

    def post_signup(bytes)
      post '/api/provisioning/v1/signups', params: { signup: { organisation_name: 'x' * bytes } }.to_json,
                                           headers: { 'Authorization' => "Bearer #{secret}", 'CONTENT_TYPE' => 'application/json' }
    end

    it 'still reads a body of 5 KB and refuses one over 16 KB in its own envelope' do
      watching_the_parser do |parsed|
        post_signup(5.kilobytes)
        expect(response).not_to have_http_status(:content_too_large)
        expect(parsed).to be_present

        post_signup(Lalabase::ProvisioningConfiguration::MAX_BODY_BYTES + 1_000)
        expect(response).to have_http_status(:content_too_large)
        expect(response.parsed_body).to eq('error' => { 'code' => 'body_too_large', 'messages' => [] })
      end
    end
  end

  it 'leaves every other address alone' do
    get '/api/auth/v1/methods', headers: { 'CONTENT_LENGTH' => (limit + 1).to_s }
    expect(response).to have_http_status(:content_too_large)

    post '/users/sign_in', params: { user: { email: 'person@example.com', password: 'x' * (limit + 1) } }
    expect(response).not_to have_http_status(:content_too_large)
  end
end
