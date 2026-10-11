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
require 'rails_helper'

RSpec.describe PriceTier do
  describe '#amount_cents_for' do
    context 'with a flat rung (base amount only)' do
      subject(:tier) do
        build(:price_tier, min_seats: 7, max_seats: 10, base_amount_cents: 10_000,
                           per_seat_amount_cents: 0)
      end

      it 'charges the same amount across the whole rung' do
        expect(tier.amount_cents_for(7)).to eq(10_000)
        expect(tier.amount_cents_for(10)).to eq(10_000)
      end
    end

    context 'with the open-ended per-seat rung' do
      subject(:tier) do
        build(:price_tier, min_seats: 11, max_seats: nil, base_amount_cents: 0,
                           per_seat_amount_cents: 1000)
      end

      # THE decisive test of this model. per_seat multiplies ALL seats, not just
      # those above min_seats -- reading it the other way yields 10 EUR at
      # eleven seats instead of 110, and nothing else in the system would
      # notice. It also pins the seamless join to the 100 EUR cap at ten seats.
      it 'multiplies every seat, not only those above min_seats' do
        expect(tier.amount_cents_for(11)).to eq(11_000)
        expect(tier.amount_cents_for(20)).to eq(20_000)
      end
    end

    it 'adds base and per-seat components when both are set' do
      tier = build(:price_tier, base_amount_cents: 5000, per_seat_amount_cents: 250)

      expect(tier.amount_cents_for(4)).to eq(6000)
    end
  end

  describe 'the V4 ladder as a whole' do
    let(:list) { create(:price_list, :with_v4_monthly_ladder) }

    # Walks the published price table seat by seat. Guards both the amounts
    # themselves and the gapless-ness of the ladder: every seat count from 1
    # upwards must hit exactly one rung.
    {
      1 => 2900, 2 => 2900, 3 => 4400, 4 => 5900, 5 => 7400,
      6 => 8900, 7 => 10_000, 10 => 10_000, 11 => 11_000, 25 => 25_000
    }.each do |seats, expected_cents|
      it "charges #{expected_cents} cents for #{seats} seat(s)" do
        matching = list.tiers.select { |tier| tier.covers?(seats) }

        expect(matching.size).to eq(1)
        expect(matching.first.amount_cents_for(seats)).to eq(expected_cents)
      end
    end

    it 'leaves no seat count uncovered between 1 and 200' do
      uncovered = (1..200).reject { |seats| list.tiers.any? { |tier| tier.covers?(seats) } }

      expect(uncovered).to be_empty
    end

    it 'never lets two rungs claim the same seat count' do
      ambiguous = (1..200).select { |seats| list.tiers.count { |tier| tier.covers?(seats) } > 1 }

      expect(ambiguous).to be_empty
    end
  end

  describe '#covers?' do
    subject(:tier) { build(:price_tier, min_seats: 3, max_seats: 6) }

    it 'excludes the seat count below the rung' do
      expect(tier.covers?(2)).to be(false)
    end

    it 'includes both boundaries' do
      expect(tier.covers?(3)).to be(true)
      expect(tier.covers?(6)).to be(true)
    end

    it 'excludes the seat count above the rung' do
      expect(tier.covers?(7)).to be(false)
    end

    it 'has no upper bound when max_seats is nil' do
      open_tier = build(:price_tier, min_seats: 11, max_seats: nil)

      expect(open_tier.covers?(10_000)).to be(true)
    end
  end

  describe 'yearly amounts' do
    # Yearly rows store the YEARLY amount, not the monthly equivalent -- storing
    # 2320 instead of 27840 would multiply a rounding error twelvefold into the
    # invoice (§4).
    it 'stores the amount per billing period, not per month' do
      tier = create(:price_tier, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                                 base_amount_cents: 27_840)

      expect(tier.amount_cents_for(2)).to eq(27_840)
    end
  end

  describe 'validations' do
    it 'rejects an unknown billing interval' do
      expect(build(:price_tier, billing_interval: 'weekly')).not_to be_valid
    end

    it 'rejects min_seats below 1' do
      expect(build(:price_tier, min_seats: 0)).not_to be_valid
    end

    it 'rejects max_seats below min_seats' do
      tier = build(:price_tier, min_seats: 5, max_seats: 4)

      expect(tier).not_to be_valid
      expect(tier.errors[:max_seats]).to be_present
    end

    it 'accepts max_seats equal to min_seats (a single-seat rung)' do
      expect(build(:price_tier, min_seats: 3, max_seats: 3)).to be_valid
    end

    it 'accepts a zero amount (promotional rung)' do
      expect(build(:price_tier, base_amount_cents: 0, per_seat_amount_cents: 0)).to be_valid
    end

    it 'rejects a negative amount' do
      expect(build(:price_tier, base_amount_cents: -1)).not_to be_valid
    end
  end

  describe 'uniqueness of a rung within one list and interval' do
    let(:list) { create(:price_list) }

    it 'refuses a second rung with the same min_seats in the same interval' do
      create(:price_tier, price_list: list, min_seats: 3, max_seats: 3)

      duplicate = build(:price_tier, price_list: list, min_seats: 3, max_seats: 4)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows the same min_seats in a different interval' do
      create(:price_tier, price_list: list, min_seats: 3, max_seats: 3)

      yearly = build(:price_tier, price_list: list, min_seats: 3, max_seats: 3,
                                  billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)

      expect(yearly).to be_valid
      expect { yearly.save! }.not_to raise_error
    end
  end
end
