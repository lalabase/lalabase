# frozen_string_literal: true

FactoryBot.define do
  factory :conversation do
    organisation { ActsAsTenant.current_tenant || association(:organisation) }
    creator { association(:user) }
    title { 'Angebot für das Beispielprojekt' }

    trait :untitled do
      title { nil }
    end

    # The project is a label: a project of the conversation's own organisation.
    trait :labelled do
      project { association(:project, organisation: organisation) }
    end
  end
end
