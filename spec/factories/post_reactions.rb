# frozen_string_literal: true

FactoryBot.define do
  factory :post_reaction do
    association :post
    association :user
    organisation { post.organisation }
    emoji { '👍' }
  end
end
