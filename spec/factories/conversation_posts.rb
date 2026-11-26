# frozen_string_literal: true

FactoryBot.define do
  factory :conversation_post do
    conversation
    organisation { conversation.organisation }
    user { association(:user) }

    # The text of a message. Not an attribute of the factory: assigning even nil
    # to `content` builds a rich text record, and a system entry has none.
    transient do
      body { 'Guten Morgen, hier ist der Stand.' }
    end

    after(:build) do |post, evaluator|
      post.content = evaluator.body if post.message? && evaluator.body && post.rich_text_content.nil?
    end

    trait :system do
      kind { 'system' }
      system_event { 'participant_added' }
    end
  end
end
