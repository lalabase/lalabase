# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_usage_rollups
#
#  id                :uuid             not null, primary key
#  aggregated_at     :datetime         not null
#  cost_cents        :decimal(15, 6)   default(0.0), not null
#  credits_used      :bigint           default(0), not null
#  organisation_name :string           not null
#  partial           :boolean          default(FALSE), not null
#  period_start      :date             not null
#  tokens_used       :bigint           default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :uuid             not null
#  organisation_id   :uuid             not null
#
# Indexes
#
#  idx_ai_usage_rollups_account_period  (account_id,period_start)
#  idx_ai_usage_rollups_unique_period   (organisation_id,period_start) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
FactoryBot.define do
  # Defaults describe the END STATE these rows exist for: the organisation is
  # gone, and only the rollup still knows what it consumed. Pass an explicit
  # organisation_id/organisation_name for the "org still alive" case.
  factory :ai_usage_rollup do
    account
    organisation_id { SecureRandom.uuid }
    organisation_name { 'Geloeschte Organisation' }
    period_start { Date.current.prev_month.beginning_of_month }
    credits_used { 100 }
    tokens_used { 5_000 }
    cost_cents { 250 }
    aggregated_at { Time.current }
  end
end
