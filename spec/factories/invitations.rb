# frozen_string_literal: true

# == Schema Information
#
# Table name: invitations
#
#  id              :uuid             not null, primary key
#  accepted_at     :datetime
#  email           :string
#  sent_at         :datetime
#  token           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  inviter_id      :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_invitations_on_organisation_id  (organisation_id)
#  index_invitations_on_token            (token) UNIQUE
#
FactoryBot.define do
  factory :invitation do
    organisation
    email { Faker::Internet.email }
    token { SecureRandom.hex(20) }
    sent_at { 1.day.ago }
    accepted_at { nil }
    association :inviter, factory: :user
  end
end
