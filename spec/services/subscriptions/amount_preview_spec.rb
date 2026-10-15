# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::AmountPreview do
  let(:today) { Date.new(2026, 8, 3) }
  let(:account) { create(:account) }
  let(:seats) { 5 }

  # SeatCounter is stubbed WITH the concrete account, not blanket-stubbed: it
  # has its own specs, and building billable memberships across organisations
  # here would test the counter a second time instead of this class. The `.with`
  # keeps the stub honest -- a call for a different account would fail loudly.
  before do
    counter = instance_double(Subscriptions::SeatCounter, call: seats)
    allow(Subscriptions::SeatCounter).to receive(:new).with(account).and_return(counter)
  end

  def preview(**overrides)
    described_class.call(account: account, on: today, **overrides)
  end

  context 'without any price level' do
    it 'reports the price as missing' do
      expect(preview).to be_price_missing
    end

    # 0 would read as "free" where the truth is "unknown" -- the distinction
    # this whole result object exists for.
    it 'leaves the amounts nil rather than zero' do
      result = preview

      expect(result.subtotal_cents).to be_nil
      expect(result.total_cents).to be_nil
      expect(result.discount_cents).to be_nil
    end

    it 'still reports the seat count it resolved' do
      expect(preview.seats).to eq(5)
    end
  end

  context 'with the V4 ladder and no discount' do
    before { create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1.day, ends_on: nil) }

    it 'charges the rung amount for the current seat count' do
      result = preview

      expect(result.subtotal_cents).to eq(7400)
      expect(result.total_cents).to eq(7400)
      expect(result).not_to be_price_missing
    end

    it 'reports no discount' do
      result = preview

      expect(result.discount_percent).to eq(0)
      expect(result.discount_cents).to eq(0)
      expect(result).not_to be_discounted
    end

    it 'names the rung it landed on, so 100 EUR at 8 seats is explainable' do
      expect(preview.tier).to be_a(PriceTier)
      expect(preview.tier.covers?(5)).to be(true)
    end

    context 'when the account has no paid seat' do
      let(:seats) { 0 }

      it 'does not invent the base rung' do
        expect(preview.tier).to be_nil
        expect(preview.total_cents).to be_nil
      end

      # "Nobody to bill" and "no price level exists" are different states. This
      # spec previously asserted they were the same, which is how the account
      # page came to claim a missing price level while the admin banner and the
      # rake check both reported one in force.
      it 'reports no billable seats rather than a missing price' do
        expect(preview).to be_no_billable_seats
        expect(preview).not_to be_price_missing
      end
    end
  end

  context 'with an active discount' do
    before { create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1.day, ends_on: nil) }

    it 'subtracts the percentage from the rung amount' do
      create(:account_discount, account: account, percent_off: 50,
                                starts_on: today - 1.day, ends_on: today + 6.months)

      result = preview

      expect(result.subtotal_cents).to eq(7400)
      expect(result.discount_percent).to eq(50)
      expect(result.discount_cents).to eq(3700)
      expect(result.total_cents).to eq(3700)
    end

    it 'waives the whole amount at 100 percent' do
      create(:account_discount, account: account, percent_off: 100,
                                starts_on: today, ends_on: nil)

      expect(preview.total_cents).to eq(0)
    end

    it 'ignores a discount that has already expired' do
      create(:account_discount, account: account, percent_off: 50,
                                starts_on: today - 90.days, ends_on: today - 1.day)

      expect(preview.discount_percent).to eq(0)
      expect(preview.total_cents).to eq(7400)
    end

    it 'ignores a discount that has not started yet' do
      create(:account_discount, account: account, percent_off: 50,
                                starts_on: today + 1.day, ends_on: nil)

      expect(preview.discount_percent).to eq(0)
    end

    it 'still applies on the discount last day (ends_on is inclusive)' do
      create(:account_discount, account: account, percent_off: 20,
                                starts_on: today - 30.days, ends_on: today)

      expect(preview.discount_percent).to eq(20)
    end

    it 'ignores a discount belonging to a different account' do
      create(:account_discount, account: create(:account), percent_off: 50,
                                starts_on: today, ends_on: nil)

      expect(preview.discount_percent).to eq(0)
    end
  end

  describe 'rounding of the discount' do
    # Rounds half up on the cent and rounds the DISCOUNT, not the total:
    # integer division would truncate downwards, always to the customer's
    # disadvantage. 1233 * 33% = 406.89 -> 407, not 406.
    it 'rounds a fractional cent up rather than truncating it' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, min_seats: 1, max_seats: nil, base_amount_cents: 1233)
      create(:account_discount, account: account, percent_off: 33, starts_on: today, ends_on: nil)

      result = preview

      expect(result.discount_cents).to eq(407)
      expect(result.total_cents).to eq(826)
    end

    # round, not ceil or floor: the three differ only on a fractional cent, and
    # without a case that lands exactly there, swapping them would go unnoticed.
    # 1001 * 25% = 250.25 -> 250 (round/floor agree, ceil would say 251);
    # 1003 * 25% = 250.75 -> 251 (round/ceil agree, floor would say 250).
    it 'rounds down below the half cent' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, min_seats: 1, max_seats: nil, base_amount_cents: 1001)
      create(:account_discount, account: account, percent_off: 25, starts_on: today, ends_on: nil)

      expect(preview.discount_cents).to eq(250)
    end

    it 'rounds up above the half cent' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, min_seats: 1, max_seats: nil, base_amount_cents: 1003)
      create(:account_discount, account: account, percent_off: 25, starts_on: today, ends_on: nil)

      expect(preview.discount_cents).to eq(251)
    end

    it 'never loses a cent between subtotal, discount and total' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, min_seats: 1, max_seats: nil, base_amount_cents: 999)
      create(:account_discount, account: account, percent_off: 17, starts_on: today, ends_on: nil)

      result = preview

      expect(result.subtotal_cents - result.discount_cents).to eq(result.total_cents)
    end
  end

  describe 'preloaded price level' do
    # Same escape hatch as seats:, and for the same reason -- without it every
    # iteration of a loop (the public pricing page, an account list) resolves
    # the level again and turns into an N+1.
    it 'uses a passed-in price level instead of resolving one' do
      price_list = create(:price_list, :with_v4_monthly_ladder, starts_on: today, ends_on: nil)

      expect(Subscriptions::PriceLookup).not_to receive(:current)

      result = described_class.call(account: account, on: today, price_list: price_list)

      expect(result.subtotal_cents).to eq(7400)
    end
  end

  describe 'yearly interval' do
    it 'previews the yearly amount, not a monthly one' do
      list = create(:price_list, starts_on: today, ends_on: nil)
      create(:price_tier, price_list: list, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                          min_seats: 1, max_seats: nil, base_amount_cents: 71_040)

      result = preview(billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)

      expect(result.subtotal_cents).to eq(71_040)
    end
  end

  # Both of these are relied upon by Subscriptions::BillingList and by nothing
  # else today. Pinned HERE rather than only from over there, so that whoever
  # rebuilds this class breaks their own suite instead of the billing list.
  describe 'contract with callers that resolved the price level themselves' do
    # The whole point of the sentinel: a plain truthiness check treated
    # "explicitly nil" like "no argument" and sent every caller back to a
    # lookup -- the exact N+1 the argument exists to prevent.
    it 'does not look up a price level when nil was passed explicitly' do
      allow(Subscriptions::PriceLookup).to receive(:current).and_call_original
      allow(Subscriptions::PriceLookup).to receive(:tier_for).and_call_original

      result = preview(price_list: nil)

      expect(result).to be_price_missing
      expect(Subscriptions::PriceLookup).not_to have_received(:tier_for)
      expect(Subscriptions::PriceLookup).not_to have_received(:current)
    end

    it 'still looks one up when no argument was given at all' do
      allow(Subscriptions::PriceLookup).to receive(:tier_for).and_call_original

      preview

      expect(Subscriptions::PriceLookup).to have_received(:tier_for)
    end
  end

  describe 'the discount on the no-rung path' do
    before { create(:account_discount, account: account, percent_off: 100, starts_on: today - 1) }

    # The discount belongs to the ACCOUNT, not to the arithmetic. Dropping it
    # here made a 100 % discounted account without a billable seat read as
    # "no discount" to every caller that asks the result rather than the account.
    it 'is carried even when no rung applies' do
      result = preview

      expect(result.tier).to be_nil
      expect(result.discount_percent).to eq(100)
    end

    # A trap worth naming rather than leaving for the next caller: the
    # percentage is known while the amounts are not. Today unreachable in the
    # two views, because both ask no_billable_seats?/price_missing? first and
    # those two cover tier.nil? exhaustively.
    it 'reports discounted? without having any amounts to show' do
      result = preview

      expect(result).to be_discounted
      expect(result.discount_cents).to be_nil
      expect(result.total_cents).to be_nil
    end
  end

  # The third case beside price_missing? and no_billable_seats? (R1 plan § 8).
  # It is a statement about the ACCOUNT, so it holds on every path through the
  # class -- with a price level and without one.
  describe '#billing_start_undecided?' do
    it 'is true while no start date has been decided' do
      create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1)

      expect(preview).to be_billing_start_undecided
    end

    it 'is false once a start date exists' do
      create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1)
      account.update!(billing_starts_on: today)

      expect(preview).not_to be_billing_start_undecided
    end

    # A decision about the future is still a decision.
    it 'is false for a start date that is still ahead' do
      create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1)
      account.update!(billing_starts_on: today + 30)

      expect(preview).not_to be_billing_start_undecided
    end

    # The other construction path: no tier at all. Leaving the flag to its
    # default here would report "undecided" for an account that IS billed.
    it 'is carried on the no-price path as well' do
      account.update!(billing_starts_on: today)

      result = preview

      expect(result).to be_price_missing
      expect(result).not_to be_billing_start_undecided
    end

    # The amount stays computed: an operator screen may legitimately show what
    # this account WOULD cost. Only customer-facing pages hide it.
    it 'does not blank out the amount it applies to' do
      create(:price_list, :with_v4_monthly_ladder, starts_on: today - 1)

      result = preview

      expect(result).to be_billing_start_undecided
      expect(result.total_cents).to be_positive
    end
  end

  # Two prices for the same product (§13 of doc/billing_preisliste_rabatt_plan.md):
  # the account's booked plan decides which level applies, so a caller that only
  # passes the account cannot price it on the wrong plan.
  describe 'the plan' do
    def publish(plan_key, per_seat_cents)
      list = create(:price_list, plan_key: plan_key, starts_on: today - 1.day, ends_on: nil)
      create(:price_tier, price_list: list, min_seats: 1, max_seats: nil,
                          base_amount_cents: 0, per_seat_amount_cents: per_seat_cents)
    end

    before do
      publish(Subscriptions::Constants::PLAN_CLOUD, 1000)
      publish(Subscriptions::Constants::PLAN_CLOUD_AI, 1300)
    end

    it 'prices a new account on the plan without AI' do
      expect(preview.total_cents).to eq(5000)
    end

    it 'prices an account booked on the AI plan on that plan' do
      account.update!(plan_key: Subscriptions::Constants::PLAN_CLOUD_AI)

      expect(preview.total_cents).to eq(6500)
    end

    it 'prices the other plan when a caller asks for it' do
      expect(preview(plan_key: Subscriptions::Constants::PLAN_CLOUD_AI).total_cents).to eq(6500)
    end
  end

  describe 'failure propagation' do
    # SeatCounter raises loudly on a broken organisation (D7 of the billing
    # plan). Swallowing that here would turn a countable error into a silently
    # too-low price.
    it 'does not swallow a seat-counting error' do
      broken = Subscriptions::SeatCounter
      allow(broken).to receive(:new).with(account).and_raise(ActiveRecord::RecordNotFound)

      expect { preview }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
