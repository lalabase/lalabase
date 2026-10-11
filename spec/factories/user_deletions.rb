# frozen_string_literal: true

# == Schema Information
#
# Table name: user_deletions
#
#  id                  :uuid             not null, primary key
#  canceled_at         :datetime
#  cancellation_reason :text
#  deleted_at          :datetime         not null
#  deleter_type        :string           not null
#  executed_at         :datetime
#  reason              :text
#  scheduled_at        :datetime
#  source              :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  deleted_user_id     :uuid             not null
#  deleter_id          :uuid             not null
#
# Indexes
#
#  index_user_deletions_on_deleted_at                   (deleted_at)
#  index_user_deletions_on_deleted_user_id              (deleted_user_id)
#  index_user_deletions_on_deleter_type_and_deleter_id  (deleter_type,deleter_id)
#  index_user_deletions_on_source                       (source)
#
# Foreign Keys
#
#  fk_rails_...  (deleted_user_id => users.id)
#
FactoryBot.define do
  factory :user_deletion do
    association :deleted_user, factory: :user
    association :deleter, factory: :user
    source { 'selfservice' }
    reason { 'User requested account deletion' }
    deleted_at { Time.current }

    trait :backend_deletion do
      association :deleter, factory: :beuser
      source { 'backend' }
      reason { 'Policy violation' }
    end

    trait :selfservice_deletion do
      source { 'selfservice' }
      reason { 'No longer needed' }
    end

    trait :with_beuser_deleter do
      association :deleter, factory: :beuser
    end

    trait :without_reason do
      reason { nil }
    end
  end
end
