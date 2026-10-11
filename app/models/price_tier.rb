# frozen_string_literal: true

# One rung of the seat ladder, per billing interval
# (doc/billing_preisliste_rabatt_plan.md §4/V4). Today's ladder: 1-2 seats
# 29 EUR, then +15 EUR per seat up to 6, capped at 100 EUR for 7-10, and 10 EUR
# per seat from 11 on -- the open rung joins the cap seamlessly (10 seats =
# 100 EUR, 11 seats = 110 EUR).
#
# No own date window: a rung inherits the one of its PriceList (D9).
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
class PriceTier < ApplicationRecord
  belongs_to :price_list, inverse_of: :tiers

  # Read through a lambda, not as a captured array: `in: ARRAY` binds the array
  # object at class-definition time, which would make the registry (D10) a
  # load-time snapshot -- and a third interval untestable without a restart.
  validates :billing_interval,
            inclusion: { in: ->(_tier) { Subscriptions::Constants::BILLING_INTERVAL_KEYS } }
  validates :min_seats, numericality: { only_integer: true, greater_than: 0 }
  # The upper bound is the int4 ceiling, not a business rule: without it a
  # fat-fingered amount reaches PostgreSQL and comes back as a raw
  # RangeError/NumericValueOutOfRange in the operator's flash instead of a
  # sentence. 21 million euros is far past any plausible price.
  MAX_AMOUNT_CENTS = 2_147_483_647

  validates :base_amount_cents, :per_seat_amount_cents,
            numericality: {
              only_integer: true, greater_than_or_equal_to: 0,
              less_than_or_equal_to: MAX_AMOUNT_CENTS
            }
  validate :max_seats_not_below_min_seats

  scope :for_interval, ->(billing_interval) { where(billing_interval: billing_interval) }

  # The amount formula, and the only place it exists (§4):
  #
  #   amount = base_amount_cents + per_seat_amount_cents * seats
  #
  # per_seat multiplies ALL seats, not just those above min_seats. Reading it
  # the other way makes the open rung bill 10 EUR at 11 seats instead of 110 --
  # the single most likely defect in this model, which is why the spec pins
  # exactly that case.
  #
  # Result is the amount PER BILLING PERIOD: a monthly amount for 'monthly', a
  # yearly amount for 'yearly'.
  def amount_cents_for(seats)
    base_amount_cents + (per_seat_amount_cents * seats)
  end

  # Inclusive on both ends; a nil max_seats is the open rung.
  def covers?(seats)
    seats >= min_seats && (max_seats.nil? || seats <= max_seats)
  end

  def open_ended?
    max_seats.nil?
  end

  private

  def max_seats_not_below_min_seats
    return if max_seats.blank? || min_seats.blank?
    return if max_seats >= min_seats

    errors.add(:max_seats, :below_min_seats)
  end
end
