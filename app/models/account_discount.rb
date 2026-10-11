# frozen_string_literal: true

# A percentage discount granted to one account for a period
# (doc/billing_preisliste_rabatt_plan.md D3). Granted only in the internal admin
# backend -- same class of special condition as accounts.guest_max_*, never
# editable by the account owner.
#
# Rows instead of columns on Account because a discount is worth money: who
# granted whom what, when and why stays reconstructable after it expired, and
# discounts follow one another (trial -> early adopter -> regular).
#
# Exactly ONE active discount per account, enforced by EffectiveDating's
# no-overlap rule. That is also what keeps the two planned conditions (founding
# customers / new founders, §12.3) mutually exclusive without extra logic --
# percentages must never stack or multiply.
#
# Mutability (D3) is NOT enforced here: a running discount may only be ended by
# pulling ends_on forward, a correction means delete + recreate. That rule lives
# in the write path (controller guard, P4), because a model validation would
# also block the fixtures and the seed.
# == Schema Information
#
# Table name: account_discounts
#
#  id               :uuid             not null, primary key
#  ends_on          :date
#  granted_by_email :string
#  percent_off      :integer          not null
#  reason           :string
#  starts_on        :date             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :uuid             not null
#
# Indexes
#
#  index_account_discounts_on_account_id_and_starts_on  (account_id,starts_on)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class AccountDiscount < ApplicationRecord
  include EffectiveDating

  # Two accounts may hold discounts over the same period; one account may not.
  effective_dating_scope :account_id

  belongs_to :account

  validates :percent_off,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100 }

  def open_ended?
    ends_on.nil?
  end
end
