# frozen_string_literal: true

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
FactoryBot.define do
  factory :account_discount do
    account
    percent_off { 30 }
    starts_on { Date.current }
    ends_on { Date.current + 6.months }
    reason { 'Gründungskunde' }
    granted_by_email { 'admin@example.com' }
  end
end
