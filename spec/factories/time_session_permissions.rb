# frozen_string_literal: true

# == Schema Information
#
# Table name: time_session_permissions
#
#  id             :uuid             not null, primary key
#  can_create_own :boolean          default(TRUE), not null
#  can_delete_all :boolean          default(FALSE), not null
#  can_delete_own :boolean          default(TRUE), not null
#  can_edit_all   :boolean          default(FALSE), not null
#  can_edit_own   :boolean          default(TRUE), not null
#  can_view_all   :boolean          default(FALSE), not null
#  can_view_own   :boolean          default(TRUE), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  project_id     :uuid             not null
#  user_id        :uuid             not null
#
# Indexes
#
#  index_time_session_permissions_on_project     (project_id)
#  index_time_session_permissions_on_project_id  (project_id)
#  index_time_session_permissions_on_user_id     (user_id)
#  index_time_session_permissions_unique         (user_id,project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :time_session_permission do
    association :user
    association :project

    # A time row counts only while a live ProjectPermission stands behind it
    # (TimeSessionPermission.backed_by_project_access), the way the Team page
    # sets it up. Without one the row is the leftover of a removed member.
    # project_member { false } builds exactly that leftover.
    transient do
      project_member { true }
    end

    after(:create) do |permission, evaluator|
      next unless evaluator.project_member
      next if ProjectPermission.exists?(user_id: permission.user_id, project_id: permission.project_id)

      grant = ProjectPermission.archived_for(project: permission.project, user: permission.user) ||
              ProjectPermission.new(project: permission.project, user: permission.user)
      # No project subscription as a side effect of a time-rights fixture.
      grant.skip_auto_subscribe = true
      grant.deleted_at = nil
      grant.save!
    end

    # Default values match model defaults
    can_create_own { true }
    can_view_own { true }
    can_edit_own { true }
    can_delete_own { true }
    can_view_all { false }
    can_edit_all { false }
    can_delete_all { false }

    trait :read_only do
      can_view_all { true }
      can_edit_all { false }
      can_delete_all { false }
    end

    trait :full_access do
      can_view_all { true }
      can_edit_all { true }
      can_delete_all { true }
    end

    trait :no_access do
      can_create_own { false }
      can_view_own { false }
      can_edit_own { false }
      can_delete_own { false }
      can_view_all { false }
      can_edit_all { false }
      can_delete_all { false }
    end
  end
end
