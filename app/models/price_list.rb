# frozen_string_literal: true

# One published price level for a plan (doc/billing_preisliste_rabatt_plan.md
# D9): the date window lives here, the seat ladder in PriceTier. List and tiers
# are published together in one transaction -- a half-replaced level would be a
# price nobody decided on (14 amounts per level: 7 rungs x 2 intervals).
#
# GLOBAL table, no acts_as_tenant -- operator-curated pricing, and the public
# pricing page reads it without any tenant (D7). An accidental acts_as_tenant
# here would filter every row away on /pricing without raising anything.
#
# The two ladder invariants (gapless, non-overlapping seat ranges) are NOT
# validated here: they hold for a level as a whole and are checked when it is
# published (Actors::PublishPriceList, P3). A row-level validation could never
# see a ladder under construction as valid.
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
class PriceList < ApplicationRecord
  include EffectiveDating

  # No two price levels of the same plan may overlap in time. Different plans
  # are independent -- hence the scope.
  effective_dating_scope :plan_key

  has_many :tiers, class_name: 'PriceTier', dependent: :destroy, inverse_of: :price_list

  # Lambda rather than a captured array -- see PriceTier#billing_interval.
  validates :plan_key, inclusion: { in: ->(_list) { Subscriptions::Constants::PLAN_KEYS } }
  validates :currency, presence: true

  scope :for_plan, ->(plan_key) { where(plan_key: plan_key) }
end
