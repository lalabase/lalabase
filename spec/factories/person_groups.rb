# frozen_string_literal: true

FactoryBot.define do
  factory :person_group do
    association :owner, factory: :user
  end
end
