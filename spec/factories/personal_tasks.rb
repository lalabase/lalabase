# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_tasks
#
#  id              :uuid             not null, primary key
#  completed_at    :datetime
#  position        :integer          default(0), not null
#  priority        :integer
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_personal_tasks_on_org_user_completed  (organisation_id,user_id,completed_at)
#  index_personal_tasks_on_user_id             (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
FactoryBot.define do
  factory :personal_task do
    association :organisation
    association :user
    sequence(:title) { |n| "Notiz #{n}" }
    # priority stays nil by default (= no priority); position defaults to 0.

    trait :high do
      priority { :high }
    end

    trait :done do
      completed_at { Time.current }
    end
  end
end
