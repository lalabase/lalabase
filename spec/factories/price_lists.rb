# frozen_string_literal: true

# == Schema Information
#
# Table name: price_lists
#
#  id               :uuid             not null, primary key
#  created_by_email :string
#  currency         :string           default("EUR"), not null
#  ends_on          :date
#  note             :string
#  plan_key         :string           not null
#  starts_on        :date             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_price_lists_on_plan_key_and_starts_on  (plan_key,starts_on)
#
FactoryBot.define do
  factory :price_list do
    plan_key { Subscriptions::Constants::PLAN_CLOUD }
    currency { 'EUR' }
    starts_on { Date.current }
    ends_on { nil }

    # The V4 ladder as actually sold -- monthly amounts, in cents. Used wherever
    # a spec needs a complete, gapless ladder rather than a single rung.
    trait :with_v4_monthly_ladder do
      after(:create) do |list|
        [
          [1, 2, 2900], [3, 3, 4400], [4, 4, 5900],
          [5, 5, 7400], [6, 6, 8900], [7, 10, 10_000]
        ].each do |min, max, cents|
          create(:price_tier, price_list: list, min_seats: min, max_seats: max,
                              base_amount_cents: cents, per_seat_amount_cents: 0)
        end
        # Open rung: 10 EUR per seat, joining the cap seamlessly at 11 seats.
        create(:price_tier, price_list: list, min_seats: 11, max_seats: nil,
                            base_amount_cents: 0, per_seat_amount_cents: 1000)
      end
    end

    # The yearly half of the same ladder: monthly x 12 minus the registry's 20 %,
    # exactly as PriceListSeed (in the operator engine since S3.2) derives it.
    # Combine with :with_v4_monthly_ladder
    # wherever a spec needs the switch to have something to switch to.
    trait :with_v4_yearly_ladder do
      after(:create) do |list|
        [
          [1, 2, 27_840], [3, 3, 42_240], [4, 4, 56_640],
          [5, 5, 71_040], [6, 6, 85_440], [7, 10, 96_000]
        ].each do |min, max, cents|
          create(:price_tier, price_list: list, min_seats: min, max_seats: max,
                              billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                              base_amount_cents: cents, per_seat_amount_cents: 0)
        end
        create(:price_tier, price_list: list, min_seats: 11, max_seats: nil,
                            billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                            base_amount_cents: 0, per_seat_amount_cents: 9600)
      end
    end
  end
end
