# frozen_string_literal: true

# == Schema Information
#
# Table name: founder_signups
#
#  id                   :uuid             not null, primary key
#  company_name         :string           not null
#  company_seat         :string           not null
#  decided_at           :datetime
#  decided_by_email     :string
#  founded_on           :date             not null
#  marketing_consent    :boolean          default(FALSE), not null
#  marketing_consent_at :datetime
#  note                 :text
#  phone                :string           not null
#  previous_tools       :text
#  revenue_band         :string           not null
#  status               :string           default("open"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :uuid             not null
#
# Indexes
#
#  index_founder_signups_on_account_id             (account_id) UNIQUE
#  index_founder_signups_on_status_and_created_at  (status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
FactoryBot.define do
  factory :founder_signup do
    association :account
    company_name { 'Muster GmbH' }
    company_seat { 'Hamburg' }
    founded_on { 1.year.ago.to_date }
    revenue_band { FounderSignup::REVENUE_BAND_UP_TO_50K }
    phone { '+49 40 1234567' }
    marketing_consent { false }
    status { FounderSignup::STATUS_OPEN }

    trait :granted do
      status { FounderSignup::STATUS_GRANTED }
      decided_at { Time.current }
      decided_by_email { 'admin@example.com' }
    end

    trait :declined do
      status { FounderSignup::STATUS_DECLINED }
      decided_at { Time.current }
      decided_by_email { 'admin@example.com' }
    end
  end
end
