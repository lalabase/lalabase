# frozen_string_literal: true

# == Schema Information
#
# Table name: beusers
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(FALSE)
#  email           :string
#  firstname       :string
#  lastname        :string
#  password_digest :string
#  password_token  :string
#  role            :string           default("user")
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
FactoryBot.define do
  factory :beuser do
    sequence(:email) { |n| "beuser#{n}@example.com" }
    password { 'beuser-password-123' }
    firstname { 'Backend' }
    lastname { 'User' }
    role { 'admin' }
    active { true }
  end
end
