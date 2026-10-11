# frozen_string_literal: true

require 'rails_helper'

# The limit is only worth something if the body stays UNREAD, so these examples
# watch the JSON parser itself. A status code proves nothing here: the callback
# that used to answer 413 ran long after the body had been parsed.
RSpec.describe 'Provisioning body limit' do
  let(:secret) { SecureRandom.hex(32) }
  let(:limit) { Lalabase::ProvisioningConfiguration::MAX_BODY_BYTES }

  around do |example|
    previous = Rails.configuration.x.provisioning
    Rails.configuration.x.provisioning = Lalabase::ProvisioningConfiguration.new(secret: secret)
    example.run
  ensure
    Rails.configuration.x.provisioning = previous
  end

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

  def post_body(body, path: '/api/provisioning/v1/signups', authorization: "Bearer #{secret}")
    post path, params: body, headers: { 'Authorization' => authorization, 'CONTENT_TYPE' => 'application/json' }
  end

  def body_of(bytes)
    { signup: { organisation_name: 'x' * bytes } }.to_json
  end

  it 'refuses an oversized body without reading it' do
    watching_the_parser do |parsed|
      post_body(body_of(limit + 1_000))

      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig('error', 'code')).to eq('body_too_large')
      expect(parsed).to be_empty
    end
  end

  # Without a valid secret the request is worth even less work, and this is the
  # case the controller could never have caught: authentication answered first,
  # after the parser had already run.
  it 'refuses an oversized body from an unauthenticated caller without reading it' do
    watching_the_parser do |parsed|
      post_body(body_of(limit + 1_000), authorization: 'Bearer wrong')

      expect(response).to have_http_status(:content_too_large)
      expect(parsed).to be_empty
    end
  end

  # Rails routes the padded path to the same action, so a raw prefix test would
  # hand exactly this request to the parser.
  it 'is not bypassed by padding the path' do
    watching_the_parser do |parsed|
      post_body(body_of(limit + 1_000), path: '//api/provisioning/v1/signups')

      expect(response).to have_http_status(:content_too_large)
      expect(parsed).to be_empty
    end
  end

  # The finding this guards against: the check used to sit behind
  # Rack::MethodOverride, which reads the form body of every POST looking for
  # _method. A form-encoded request was therefore parsed in full before the
  # limit ever ran, and the 413 said nothing about that.
  describe 'its place in the middleware stack' do
    def stack
      Rails.application.middleware.map(&:name)
    end

    it 'runs before anything that reads a body' do
      expect(stack.index('Lalabase::ProvisioningBodyLimit'))
        .to be < stack.index('Rack::MethodOverride')
    end

    it 'refuses an oversized form body too' do
      post '/api/provisioning/v1/signups',
           params: { 'signup[organisation_name]' => 'x' * (limit + 1_000) },
           headers: { 'Authorization' => "Bearer #{secret}" }

      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body.dig('error', 'code')).to eq('body_too_large')
    end
  end

  # Proves the watch above can see anything at all: without this, "the parser
  # never ran" would also pass for a probe that never worked.
  it 'lets an ordinary signup through, and that one IS parsed' do
    watching_the_parser do |parsed|
      post_body({ signup: { email: 'within@example.com', password: 'password123',
                            password_confirmation: 'password123', first_name: 'A', last_name: 'B',
                            language: 'de', terms_accepted: true } }.to_json)

      expect(response).to have_http_status(:created)
      expect(parsed).to be_present
    end
  end
end
