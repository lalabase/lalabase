# frozen_string_literal: true

# == Schema Information
#
# Table name: user_activities
#
#  id                :uuid             not null, primary key
#  action            :string           not null
#  attribute_changes :jsonb
#  category          :string           not null
#  failure_reason    :text
#  ip_address        :string
#  metadata          :jsonb
#  status            :string           default("success")
#  trackable_type    :string
#  user_agent        :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid
#  session_id        :string
#  trackable_id      :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  idx_user_activities_on_category_and_time  (category,created_at)
#  idx_user_activities_on_created_at         (created_at)
#  idx_user_activities_on_ip_and_time        (ip_address,created_at)
#  idx_user_activities_on_org_and_time       (organisation_id,created_at)
#  idx_user_activities_on_session            (session_id)
#  idx_user_activities_on_trackable          (trackable_type,trackable_id)
#  idx_user_activities_on_user_action_time   (user_id,action,created_at)
#  idx_user_activities_on_user_and_time      (user_id,created_at)
#  index_user_activities_on_organisation_id  (organisation_id)
#  index_user_activities_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :user_activity do
    association :user
    association :organisation
    action { UserActivity::ACTIONS[:login] }
    category { UserActivity::CATEGORIES[:auth] }
    status { UserActivity::STATUSES[:success] }
    metadata { {} }
    attribute_changes { {} }

    trait :login do
      action { UserActivity::ACTIONS[:login] }
      category { UserActivity::CATEGORIES[:auth] }
    end

    trait :login_failed do
      action { UserActivity::ACTIONS[:login_failed] }
      category { UserActivity::CATEGORIES[:auth] }
      status { UserActivity::STATUSES[:failed] }
      failure_reason { 'Invalid credentials' }
    end

    trait :with_request_info do
      ip_address { '192.168.1.1' }
      user_agent { 'Mozilla/5.0 (Test)' }
      session_id { SecureRandom.hex(16) }
    end

    trait :profile_updated do
      action { UserActivity::ACTIONS[:profile_updated] }
      category { UserActivity::CATEGORIES[:profile] }
    end

    trait :role_assigned do
      action { UserActivity::ACTIONS[:role_assigned] }
      category { UserActivity::CATEGORIES[:permissions] }
      metadata { { 'role_name' => 'Admin' } }
    end

    trait :account_locked do
      action { UserActivity::ACTIONS[:account_locked] }
      category { UserActivity::CATEGORIES[:security] }
      status { UserActivity::STATUSES[:failed] }
      metadata { { 'reason' => 'Too many failed attempts' } }
    end

    trait :suspicious_activity do
      action { UserActivity::ACTIONS[:suspicious_activity] }
      category { UserActivity::CATEGORIES[:security] }
      status { UserActivity::STATUSES[:failed] }
    end

    trait :invitation_sent do
      action { UserActivity::ACTIONS[:invitation_sent] }
      category { UserActivity::CATEGORIES[:invitations] }
      metadata { { 'invited_email' => 'invited@example.com' } }
    end
  end
end
