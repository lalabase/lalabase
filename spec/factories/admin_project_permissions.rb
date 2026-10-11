# frozen_string_literal: true

FactoryBot.define do
  # The area lists below are spelled out on purpose rather than derived from
  # ProjectPermission.access_areas: an area missing here is caught loudly by
  # spec/models/admin/project_permission_spec.rb (its factory examples iterate
  # the real area list), whereas a derived factory would quietly follow along and
  # cover the drift up.
  factory :admin_project_permission, class: 'Admin::ProjectPermission' do
    user_id { create(:user).id }
    project_id { create(:project).id }
    tickets_access { 'no_access' }
    notes_access { 'no_access' }
    chats_access { 'no_access' }
    documents_access { 'no_access' }
    members_access { 'no_access' }
    documentation_access { 'no_access' }
    meetings_access { 'no_access' }

    trait :full_access do
      tickets_access { 'read_write' }
      notes_access { 'read_write' }
      chats_access { 'read_write' }
      documents_access { 'read_write' }
      members_access { 'read_write' }
      documentation_access { 'read_write' }
      meetings_access { 'read_write' }
    end

    trait :read_only_access do
      tickets_access { 'read_only' }
      notes_access { 'read_only' }
      chats_access { 'read_only' }
      documents_access { 'read_only' }
      members_access { 'read_only' }
      documentation_access { 'read_only' }
      meetings_access { 'read_only' }
    end

    trait :tickets_only do
      tickets_access { 'read_write' }
    end

    trait :mixed_access do
      tickets_access { 'read_write' }
      notes_access { 'read_only' }
      chats_access { 'no_access' }
      documents_access { 'read_write' }
      members_access { 'read_only' }
    end

    trait :soft_deleted do
      deleted_at { 1.day.ago }
    end
  end
end
