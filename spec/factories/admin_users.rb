# frozen_string_literal: true

FactoryBot.define do
  factory :admin_user, class: 'Admin::User' do
    sequence(:email) { |n| "admin_user#{n}@example.com" }
    first_name { 'Admin' }
    last_name { 'User' }
    active { true }

    trait :inactive do
      active { false }
    end

    trait :soft_deleted do
      deleted_at { 1.day.ago }
    end

    trait :with_scheduled_deletion do
      scheduled_deletion_at { 30.days.from_now }
    end

    trait :recommended_for_deletion do
      deletion_recommended { true }
    end
  end
end
