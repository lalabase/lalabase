# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::PublicPriceListPayload do
  subject(:payload) { described_class.call(price_list: price_list) }

  let(:price_list) do
    create(:price_list, :with_v4_monthly_ladder, :with_v4_yearly_ladder,
           created_by_email: 'operator@example.com', note: 'Internal note')
  end
  let(:fixture) do
    JSON.parse(Rails.root.join('spec/fixtures/api/public/v1/price_list.json').read).deep_symbolize_keys
  end
  let(:required_v1_key_paths) do
    %w[
      data
      data.price_list
      data.price_list.plan
      data.price_list.currency
      data.price_list.billing_intervals
      data.price_list.billing_intervals[].key
      data.price_list.billing_intervals[].months
      data.price_list.tiers
      data.price_list.tiers[].billing_interval
      data.price_list.tiers[].min_seats
      data.price_list.tiers[].max_seats
      data.price_list.tiers[].base_amount_cents
      data.price_list.tiers[].per_seat_amount_cents
    ]
  end

  it 'serializes the published price contract exactly as the shared website fixture' do
    expect(payload).to eq(fixture)
  end

  it 'keeps all released v1 key paths even when the shared fixture changes' do
    expect(key_paths(fixture)).to include(*required_v1_key_paths)
  end

  it 'returns a null price list in the stable envelope when none is published' do
    expect(described_class.call(price_list: nil)).to eq(data: { price_list: nil })
  end

  it 'lists only billing intervals that have published tiers, in registry order' do
    list = create(:price_list)
    create(:price_tier, price_list: list)
    create(:price_tier, price_list: list, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)
    stub_const('Subscriptions::Constants::BILLING_INTERVAL_KEYS', %w[yearly monthly].freeze)

    result = described_class.call(price_list: list)

    expect(result.dig(:data, :price_list, :billing_intervals)).to eq(
      [{ key: 'yearly', months: 12 }, { key: 'monthly', months: 1 }]
    )
  end

  it 'orders tiers by interval registry order and then by their lower seat bound' do
    list = create(:price_list)
    create(:price_tier, price_list: list, min_seats: 3, max_seats: 4, base_amount_cents: 4400)
    create(:price_tier, price_list: list, min_seats: 1, max_seats: 2, base_amount_cents: 2900)
    create(:price_tier, price_list: list, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                        min_seats: 1, max_seats: 2, base_amount_cents: 27_840)
    stub_const('Subscriptions::Constants::BILLING_INTERVAL_KEYS', %w[yearly monthly].freeze)

    result = described_class.call(price_list: list)

    expect(result.dig(:data, :price_list, :tiers).map { |tier| [tier[:billing_interval], tier[:min_seats]] }).to eq(
      [['yearly', 1], ['monthly', 1], ['monthly', 3]]
    )
  end

  it 'omits stored tiers whose billing interval is no longer registered' do
    list = create(:price_list)
    create(:price_tier, price_list: list)
    legacy = create(:price_tier, price_list: list,
                                 billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)
    legacy.update_column(:billing_interval, 'legacy')

    result = described_class.call(price_list: list).dig(:data, :price_list)

    expect(result.fetch(:billing_intervals)).to eq([{ key: 'monthly', months: 1 }])
    expect(result.fetch(:tiers).pluck(:billing_interval)).to eq(['monthly'])
  end

  def key_paths(value, prefix = nil)
    case value
    when Hash
      value.flat_map do |key, child|
        path = [prefix, key].compact.join('.')
        [path, *key_paths(child, path)]
      end
    when Array
      value.flat_map { |child| key_paths(child, "#{prefix}[]") }.uniq
    else
      []
    end
  end
end
