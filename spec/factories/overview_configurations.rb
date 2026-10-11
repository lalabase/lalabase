# frozen_string_literal: true

FactoryBot.define do
  factory :overview_configuration do
    association :organisation
    association :user
    layout { Overview::WidgetRegistry::SYSTEM_DEFAULT_LAYOUT }

    trait :org_default do
      user { nil }
    end
  end
end
