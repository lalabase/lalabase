# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/public/v1/price_list' do
  include ActiveSupport::Testing::TimeHelpers

  let(:today) { Date.new(2026, 9, 15) }
  let(:fixture) { JSON.parse(Rails.root.join('spec/fixtures/api/public/v1/price_list.json').read) }

  around do |example|
    travel_to(Time.zone.local(2026, 9, 15, 12)) { example.run }
  end

  def publish_current_list(**attributes)
    create(:price_list, :with_v4_monthly_ladder, :with_v4_yearly_ladder,
           starts_on: today, ends_on: nil, **attributes)
  end

  it 'is public and returns the exact version-one contract without internal fields' do
    publish_current_list(created_by_email: 'operator@example.com', note: 'Internal note')

    get '/api/public/v1/price_list'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(fixture)
    expect(response.headers).not_to have_key('Set-Cookie')
  end

  it 'returns a null price list in the stable envelope when none is currently published' do
    get '/api/public/v1/price_list'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('data' => { 'price_list' => nil })
  end

  it 'does not expose a price list announced for the future' do
    publish_current_list(starts_on: today + 1.day)

    get '/api/public/v1/price_list'

    expect(response.parsed_body).to eq('data' => { 'price_list' => nil })
  end

  it 'still exposes a price list on its inclusive ending date' do
    publish_current_list(starts_on: today - 1.month, ends_on: today)

    get '/api/public/v1/price_list'

    expect(response.parsed_body).to eq(fixture)
  end

  it 'uses the configured public cache TTL and answers a matching ETag with 304' do
    publish_current_list
    get '/api/public/v1/price_list'
    etag = response.headers.fetch('ETag')
    max_age = Api::Public::V1::PriceListsController::CACHE_TTL.to_i

    expect(response.headers.fetch('Cache-Control')).to include('public', "max-age=#{max_age}")

    get '/api/public/v1/price_list', headers: { 'If-None-Match' => etag }

    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
    expect(response.headers.fetch('Cache-Control')).to include('public', "max-age=#{max_age}")
  end

  it 'changes the ETag when the response body changes' do
    list = publish_current_list
    get '/api/public/v1/price_list'
    old_etag = response.headers.fetch('ETag')
    list.update_column(:currency, 'USD')

    get '/api/public/v1/price_list', headers: { 'If-None-Match' => old_etag }

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch('ETag')).not_to eq(old_etag)
    expect(response.parsed_body.dig('data', 'price_list', 'currency')).to eq('USD')
  end
end
