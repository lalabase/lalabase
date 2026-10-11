# frozen_string_literal: true

# == Schema Information
#
# Table name: price_tiers
#
#  id                    :uuid             not null, primary key
#  base_amount_cents     :integer          default(0), not null
#  billing_interval      :string           not null
#  max_seats             :integer
#  min_seats             :integer          not null
#  per_seat_amount_cents :integer          default(0), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  price_list_id         :uuid             not null
#
# Indexes
#
#  idx_price_tiers_unique_rung_per_list  (price_list_id,billing_interval,min_seats) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (price_list_id => price_lists.id)
#
FactoryBot.define do
  factory :price_tier do
    price_list
    billing_interval { Subscriptions::Constants::INTERVAL_MONTHLY }
    min_seats { 1 }
    max_seats { 2 }
    # The V4 base rung: 29 EUR for up to two seats.
    base_amount_cents { 2900 }
    per_seat_amount_cents { 0 }
  end
end
