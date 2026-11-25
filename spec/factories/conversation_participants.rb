# frozen_string_literal: true

FactoryBot.define do
  factory :conversation_participant do
    conversation
    organisation { conversation.organisation }
    # An active member of the conversation's organisation, as the model asks.
    # Created also for a built row: the membership comes with the saved user.
    user { association(:user, strategy: :create, organisation: organisation) }

    trait :added do
      added_by { conversation.creator }
    end
  end
end
