# frozen_string_literal: true

require 'rails_helper'

# What: GET /api/auth/v1/methods says what this instance offers for signing in.
# Why: a client asks it before it sends a password anywhere, and it answers everybody.
#   So it names no version and no instance, and in the public demo, where the sign-in
#   door is shut, it offers no method.
RSpec.describe 'Sign-in methods (GET /api/auth/v1/methods)', :ci_guard, type: :request do
  let(:path) { '/api/auth/v1/methods' }

  around do |example|
    flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
    example.run
  ensure
    ENV[Lalabase::Demo::ENV_FLAG] = flag_was
  end

  it 'answers the password method and the pages a person needs when a sign-in fails' do
    get path

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      'data' => {
        'sign_in' => { 'methods' => ['password'] },
        'links' => { 'password_reset' => '/users/password/new', 'unlock' => '/users/unlock/new',
                     'confirmation' => '/users/confirmation/new' }
      }
    )
  end

  it 'links to pages that exist' do
    get path

    response.parsed_body.dig('data', 'links').each_value do |link|
      expect(Rails.application.routes.recognize_path(link, method: :get)).to include(action: 'new')
    end
  end

  it 'names no version, no instance and no account, and needs no token' do
    create(:user, email: 'person@example.com')

    get path, headers: { 'Host' => 'instance.example.com' }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(Api::V1::Capabilities::API_VERSION, 'instance.example.com', 'person@example.com')
    expect(response.body).not_to match(/version|lalabase/i)
    expect(response.headers['Cache-Control']).to eq('no-store')
    expect(response.headers['Set-Cookie']).to be_blank
  end

  it 'offers no method in the public demo, and the password method again without it' do
    ENV[Lalabase::Demo::ENV_FLAG] = Lalabase::Demo::ENABLED_VALUE
    get path

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'sign_in', 'methods')).to eq([])
    expect(response.parsed_body.dig('data', 'links').keys).to contain_exactly('password_reset', 'unlock', 'confirmation')

    ENV[Lalabase::Demo::ENV_FLAG] = nil
    get path
    expect(response.parsed_body.dig('data', 'sign_in', 'methods')).to eq(['password'])
  end

  it 'has one address: no format and no other verb' do
    get "#{path}.json"
    expect(response).to have_http_status(:not_found)

    post path
    expect(response).to have_http_status(:not_found)

    get path
    expect(response).to have_http_status(:ok)
  end
end
