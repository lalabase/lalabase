# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::PublishPriceList do
  let(:today) { Date.new(2026, 8, 3) }
  let(:monthly) { Subscriptions::Constants::INTERVAL_MONTHLY }

  # The V4 ladder as attribute hashes, the shape the admin form submits.
  def v4_ladder(interval: Subscriptions::Constants::INTERVAL_MONTHLY)
    [
      { billing_interval: interval, min_seats: 1, max_seats: 2, base_amount_cents: 2900 },
      { billing_interval: interval, min_seats: 3, max_seats: 3, base_amount_cents: 4400 },
      { billing_interval: interval, min_seats: 4, max_seats: 4, base_amount_cents: 5900 },
      { billing_interval: interval, min_seats: 5, max_seats: 5, base_amount_cents: 7400 },
      { billing_interval: interval, min_seats: 6, max_seats: 6, base_amount_cents: 8900 },
      { billing_interval: interval, min_seats: 7, max_seats: 10, base_amount_cents: 10_000 },
      { billing_interval: interval, min_seats: 11, max_seats: nil, per_seat_amount_cents: 1000 }
    ]
  end

  # A publishable submission covers EVERY billing interval -- a monthly-only
  # ladder silently removed yearly billing before the pre-landing review (P0-3).
  def complete_ladder
    Subscriptions::Constants::BILLING_INTERVAL_KEYS.flat_map { |interval| v4_ladder(interval: interval) }
  end

  def publish(starts_on: today, tiers: complete_ladder, **overrides)
    described_class.call(plan_key: Subscriptions::Constants::PLAN_CLOUD,
                         starts_on: starts_on, tiers: tiers, **overrides)
  end

  describe 'publishing a first price level' do
    it 'creates the level with its whole ladder' do
      result = publish

      expect(result).to be_success
      expect(result.resource.tiers.count).to eq(14)
    end

    it 'records the operator as an email snapshot, not a foreign key' do
      result = publish(created_by_email: 'operator@example.com')

      expect(result.resource.created_by_email).to eq('operator@example.com')
    end

    it 'leaves the level open-ended' do
      expect(publish.resource.ends_on).to be_nil
    end
  end

  describe 'replacing a predecessor' do
    let!(:predecessor) { create(:price_list, starts_on: today - 90.days, ends_on: nil) }

    it 'clips the predecessor to the day before the new level starts' do
      publish(starts_on: today + 60.days)

      expect(predecessor.reload.ends_on).to eq(today + 59.days)
    end

    it 'succeeds despite the predecessor being open-ended' do
      # Regression: creating the new level BEFORE clipping the predecessor makes
      # EffectiveDating reject it against the still-open predecessor. Order of
      # operations inside #perform is load-bearing.
      expect(publish(starts_on: today + 60.days)).to be_success
    end

    it 'leaves a predecessor alone that already ends earlier' do
      predecessor.update!(ends_on: today - 30.days)

      publish(starts_on: today + 60.days)

      expect(predecessor.reload.ends_on).to eq(today - 30.days)
    end

    it 'leaves no gap between predecessor and successor' do
      publish(starts_on: today + 60.days)

      expect(Subscriptions::PriceLookup.current(on: today + 59.days)).to eq(predecessor)
      expect(Subscriptions::PriceLookup.current(on: today + 60.days)).not_to eq(predecessor)
    end
  end

  describe 'ladder invariants' do
    it 'refuses a ladder that does not start at one seat' do
      broken = complete_ladder.reject { |rung| rung[:min_seats] == 1 }

      result = publish(tiers: broken)

      expect(result).not_to be_success
      expect(result.errors.join).to include('1')
    end

    it 'refuses a gap in the middle' do
      broken = complete_ladder.reject { |rung| rung[:min_seats] == 4 }

      expect(publish(tiers: broken)).not_to be_success
    end

    it 'refuses overlapping rungs' do
      broken = complete_ladder.map do |rung|
        rung[:min_seats] == 3 ? rung.merge(max_seats: 5) : rung
      end

      expect(publish(tiers: broken)).not_to be_success
    end

    it 'refuses a ladder with a silent ceiling (no open last rung)' do
      broken = complete_ladder.map do |rung|
        rung[:max_seats].nil? ? rung.merge(max_seats: 50) : rung
      end

      expect(publish(tiers: broken)).not_to be_success
    end

    it 'refuses an open rung that is not the last one' do
      broken = complete_ladder.map do |rung|
        rung[:min_seats] == 3 ? rung.merge(max_seats: nil) : rung
      end

      expect(publish(tiers: broken)).not_to be_success
    end

    it 'refuses an empty ladder' do
      expect(publish(tiers: [])).not_to be_success
    end

    # The label lookup in #message_for is the one reader of
    # admin.billing_interval.* with no rendered page behind it. It carries a
    # `default:`, so a wrong scope does not shout "translation missing" -- it
    # falls back to the raw registry key, which is exactly the bare English word
    # in a German sentence the lookup was added to remove. Without this example
    # that scope can be broken and the whole suite stays green.
    it 'names the interval in German rather than by its registry key' do
      broken = complete_ladder.reject { |rung| rung[:min_seats] == 4 }

      result = publish(tiers: broken)

      expect(result).not_to be_success
      expect(result.errors.join).to include(I18n.t('admin.billing_interval.monthly'))
      expect(result.errors.join).not_to include(Subscriptions::Constants::INTERVAL_MONTHLY)
    end

    it 'validates each interval independently' do
      # Monthly is complete, yearly has a hole -- the actor must still refuse.
      yearly_with_hole = v4_ladder(interval: Subscriptions::Constants::INTERVAL_YEARLY)
                         .reject { |rung| rung[:min_seats] == 5 }
      mixed = v4_ladder + yearly_with_hole

      expect(publish(tiers: mixed)).not_to be_success
    end

    it 'accepts a complete ladder for two intervals' do
      complete = v4_ladder + v4_ladder(interval: Subscriptions::Constants::INTERVAL_YEARLY)

      expect(publish(tiers: complete)).to be_success
    end
  end

  describe 'atomicity' do
    it 'writes nothing at all when the ladder is broken' do
      broken = complete_ladder.reject { |rung| rung[:min_seats] == 4 }

      expect { publish(tiers: broken) }.not_to change(PriceList, :count)
      expect(PriceTier.count).to eq(0)
    end

    it 'leaves the predecessor untouched when publishing fails' do
      predecessor = create(:price_list, starts_on: today - 90.days, ends_on: nil)
      broken = complete_ladder.reject { |rung| rung[:min_seats] == 4 }

      publish(starts_on: today + 60.days, tiers: broken)

      expect(predecessor.reload.ends_on).to be_nil
    end

    it 'rolls back the level when a rung is invalid' do
      invalid_amount = complete_ladder.map do |rung|
        rung[:min_seats] == 1 ? rung.merge(base_amount_cents: -1) : rung
      end

      expect { publish(tiers: invalid_amount) }.not_to change(PriceList, :count)
    end
  end

  describe 'Current.user' do
    # The admin operator is a Beuser, not a User (D8). Touching Current.user
    # here would push a Beuser into the Activity chain, which expects a User.
    it 'stays untouched' do
      expect { publish }.not_to change(Current, :user)
    end
  end
end
