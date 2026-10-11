# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::LadderValidator do
  def rung(min_seats, max_seats, base: 2900, per_seat: 0,
           interval: Subscriptions::Constants::INTERVAL_MONTHLY)
    { billing_interval: interval, min_seats: min_seats, max_seats: max_seats,
      base_amount_cents: base, per_seat_amount_cents: per_seat }
  end

  def complete_ladder
    Subscriptions::Constants::BILLING_INTERVAL_KEYS.flat_map do |interval|
      [rung(1, 2, interval: interval), rung(3, nil, base: 0, per_seat: 1500, interval: interval)]
    end
  end

  def keys_in(errors)
    errors.map { |error| error[:key] }
  end

  it 'accepts a complete ladder' do
    expect(described_class.errors_for(complete_ladder)).to be_empty
  end

  describe 'seat continuity' do
    it 'refuses a ladder not starting at one seat' do
      ladder = complete_ladder.reject { |r| r[:min_seats] == 1 }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_must_start_at_one)
    end

    it 'refuses a gap' do
      ladder = complete_ladder.map { |r| r[:min_seats] == 3 ? r.merge(min_seats: 5) : r }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_not_contiguous)
    end

    it 'refuses an overlap' do
      ladder = complete_ladder.map { |r| r[:max_seats] == 2 ? r.merge(max_seats: 4) : r }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_not_contiguous)
    end

    it 'refuses a silent ceiling' do
      ladder = complete_ladder.map { |r| r[:max_seats].nil? ? r.merge(max_seats: 50) : r }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_must_end_open)
    end

    it 'refuses an open rung that is not last' do
      ladder = complete_ladder.map { |r| r[:min_seats] == 1 ? r.merge(max_seats: nil) : r }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_open_rung_not_last)
    end
  end

  # P0-3 of the pre-landing review: publishing a monthly-only ladder used to
  # succeed, and yearly billing silently disappeared -- while every "does a
  # price apply today" check kept answering yes.
  describe 'interval completeness' do
    it 'refuses a ladder missing an entire interval' do
      monthly_only = complete_ladder.select do |r|
        r[:billing_interval] == Subscriptions::Constants::INTERVAL_MONTHLY
      end

      errors = described_class.errors_for(monthly_only)

      expect(keys_in(errors)).to include(:ladder_interval_missing)
      expect(errors.find { |e| e[:key] == :ladder_interval_missing }[:billing_interval])
        .to eq(Subscriptions::Constants::INTERVAL_YEARLY)
    end

    it 'names every missing interval, not just the first' do
      expect(keys_in(described_class.errors_for([])).count(:ladder_interval_missing))
        .to eq(Subscriptions::Constants::BILLING_INTERVAL_KEYS.size)
    end
  end

  # P0-2: a ladder of zeros passed every invariant. Nothing else in the system
  # looks at an amount -- PriceTier allows 0, the continuity check reads only
  # seat numbers, and no warning banner fires because a price level does apply.
  describe 'amounts' do
    it 'refuses a rung with neither a flat nor a per-seat amount' do
      ladder = complete_ladder.map { |r| r[:min_seats] == 1 ? r.merge(base_amount_cents: 0) : r }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_amount_missing)
    end

    it 'refuses a ladder that is zero throughout' do
      ladder = complete_ladder.map { |r| r.merge(base_amount_cents: 0, per_seat_amount_cents: 0) }

      expect(described_class.errors_for(ladder).count { |e| e[:key] == :ladder_amount_missing })
        .to eq(ladder.size)
    end

    it 'accepts a rung carrying only a per-seat amount' do
      expect(described_class.errors_for(complete_ladder)).to be_empty
    end

    # nil comes from MoneyInput and means "unreadable", which is a different
    # message than "you left it blank".
    it 'reports an unreadable amount separately' do
      ladder = complete_ladder.map { |r| r[:min_seats] == 1 ? r.merge(base_amount_cents: nil) : r }

      expect(keys_in(described_class.errors_for(ladder))).to include(:ladder_amount_unreadable)
    end

    it 'treats an absent key as zero rather than unreadable' do
      ladder = complete_ladder.map { |r| r.except(:per_seat_amount_cents) }

      expect(keys_in(described_class.errors_for(ladder))).not_to include(:ladder_amount_unreadable)
    end
  end

  it 'reports every defect at once instead of stopping at the first' do
    ladder = [rung(2, nil, base: 0)] # wrong start, no amount, missing interval

    expect(keys_in(described_class.errors_for(ladder)).uniq.size).to be >= 3
  end
end
