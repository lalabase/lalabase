# frozen_string_literal: true

# What: GET /up answers 200 without a session.
# Why: compose.yml waits on it (web's health check, and worker and Caddy start
#   only once web is healthy). Without the route the container never turned
#   healthy: production.rb exempted /up from the host check and the https
#   redirect, but no route answered it (found 2026-10-01, first Docker boot).
require 'rails_helper'

RSpec.describe 'Health check', type: :request do
  it 'answers 200 without signing in' do
    get '/up'

    expect(response).to have_http_status(:ok)
  end
end
