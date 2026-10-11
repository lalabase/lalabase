# frozen_string_literal: true

FactoryBot.define do
  factory :post_read do
    association :post
    association :user
    organisation { post.organisation }
    read_at { Time.current }
  end
end
