# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::PriceLookup do
  let(:today) { Date.new(2026, 8, 3) }

  describe '.current' do
    it 'returns nil when no price level exists at all' do
      expect(described_class.current(on: today)).to be_nil
    end

    it 'returns nil rather than raising -- a missing price is an operational state (D7)' do
      create(:price_list, starts_on: today + 1.day, ends_on: nil)

      expect { described_class.current(on: today) }.not_to raise_error
      expect(described_class.current(on: today)).to be_nil
    end

    it 'does not return a level announced for the future' do
      create(:price_list, starts_on: today - 90.days, ends_on: today - 1.day)
      announced = create(:price_list, starts_on: today + 60.days, ends_on: nil)

      expect(described_class.current(on: today)).not_to eq(announced)
    end

    it 'returns the level in force on the given date' do
      current = create(:price_list, starts_on: today - 30.days, ends_on: nil)

      expect(described_class.current(on: today)).to eq(current)
    end

    it 'still returns the level on its very last day (ends_on is inclusive)' do
      expiring = create(:price_list, starts_on: today - 30.days, ends_on: today)

      expect(described_class.current(on: today)).to eq(expiring)
    end

    it 'returns the successor on the day after the predecessor ended' do
      create(:price_list, starts_on: today - 30.days, ends_on: today - 1.day)
      successor = create(:price_list, starts_on: today, ends_on: nil)

      expect(described_class.current(on: today)).to eq(successor)
    end
  end

  describe '.tier_for -- the V4 ladder at every boundary' do
    before { create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1.day, ends_on: nil) }

    {
      1 => 2900, 2 => 2900,   # base rung ends here
      3 => 4400,              # first rung above the base
      6 => 8900,              # last rung before the cap
      7 => 10_000,            # cap begins
      10 => 10_000,           # cap ends
      11 => 11_000,           # open rung -- joins the cap seamlessly
      50 => 50_000
    }.each do |seats, expected_cents|
      it "charges #{expected_cents} cents at #{seats} seat(s)" do
        tier = described_class.tier_for(seats: seats, on: today)

        expect(tier.amount_cents_for(seats)).to eq(expected_cents)
      end
    end

    it 'returns nil for zero seats instead of quietly falling back to the base rung' do
      expect(described_class.tier_for(seats: 0, on: today)).to be_nil
    end

    it 'returns nil for a negative seat count' do
      expect(described_class.tier_for(seats: -3, on: today)).to be_nil
    end

    # The only case the seat guard actually catches: 0 and negatives already
    # fail covers?, but nil would blow up inside the comparison. tier_in is
    # public and gets called from views in later slices.
    it 'returns nil for a nil seat count instead of raising' do
      expect(described_class.tier_for(seats: nil, on: today)).to be_nil
    end

    it 'returns nil for an interval that has no rungs' do
      expect(
        described_class.tier_for(seats: 5, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                                 on: today)
      ).to be_nil
    end

    it 'returns nil on a date where no level applies' do
      expect(described_class.tier_for(seats: 5, on: today - 10.days)).to be_nil
    end
  end

  describe '.tier_for with yearly rungs' do
    it 'returns the amount per billing period, not the monthly equivalent' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                          min_seats: 1, max_seats: 2, base_amount_cents: 27_840)

      tier = described_class.tier_for(seats: 2, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                                      on: today)

      expect(tier.amount_cents_for(2)).to eq(27_840)
    end

    it 'keeps monthly and yearly rungs apart for the same seat count' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, min_seats: 1, max_seats: 2, base_amount_cents: 2900)
      create(:price_tier, price_list: list, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                          min_seats: 1, max_seats: 2, base_amount_cents: 27_840)

      monthly = described_class.tier_for(seats: 2, on: today)
      yearly = described_class.tier_for(seats: 2, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                                        on: today)

      expect(monthly.amount_cents_for(2)).to eq(2900)
      expect(yearly.amount_cents_for(2)).to eq(27_840)
    end
  end

  # The test that turns "the model is flexible enough for more intervals" (D10)
  # from a claim into a fact: a third interval exists ONLY inside this block,
  # and nothing in app/ is touched. If any production code still hardcodes the
  # monthly/yearly pair or divides by 12, this fails.
  describe 'a third billing interval, defined only in this spec' do
    let(:quarterly) { 'quarterly' }

    before do
      registry = Subscriptions::Constants::BILLING_INTERVALS.merge(
        quarterly => { months: 3, suggested_discount_percent: 5 }
      ).freeze
      stub_const('Subscriptions::Constants::BILLING_INTERVALS', registry)
      stub_const('Subscriptions::Constants::BILLING_INTERVAL_KEYS', registry.keys.freeze)
    end

    it 'accepts rungs for it' do
      list = create(:price_list, starts_on: today, ends_on: nil)

      tier = build(:price_tier, price_list: list, billing_interval: quarterly)

      expect(tier).to be_valid
    end

    it 'resolves rungs for it without any production code change' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, billing_interval: quarterly,
                          min_seats: 1, max_seats: 2, base_amount_cents: 8000)

      tier = described_class.tier_for(seats: 2, billing_interval: quarterly, on: today)

      expect(tier.amount_cents_for(2)).to eq(8000)
    end

    it 'exposes its period length instead of assuming 1 or 12 months' do
      expect(Subscriptions::Constants.months_for(quarterly)).to eq(3)
    end
  end

  describe '.months_for on an unknown interval' do
    # Raises instead of defaulting to 1: a silent fallback would turn an unknown
    # interval into a wrong monthly equivalent on the public pricing page.
    it 'fails loudly' do
      expect { Subscriptions::Constants.months_for('fortnightly') }.to raise_error(ArgumentError)
    end
  end

  describe 'multi-tenancy' do
    it 'resolves without a current tenant (the public pricing page has none)' do
      create(:price_list, :with_v4_monthly_ladder, starts_on: today, ends_on: nil)

      ActsAsTenant.with_tenant(nil) do
        expect(described_class.tier_for(seats: 3, on: today).amount_cents_for(3)).to eq(4400)
      end
    end
  end
end
