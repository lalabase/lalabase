# frozen_string_literal: true

# Include constants for typsafe event types in factories
require Rails.root.join('app/models/concerns/notifications/constants')

# == Schema Information
#
# Table name: notifications
#
#  id                 :uuid             not null, primary key
#  archived_at        :datetime
#  channel            :enum             default("in_app"), not null
#  dedupe_fingerprint :string           not null
#  delivered_at       :datetime
#  event_type         :enum             not null
#  first_event_at     :datetime         not null
#  group_count        :integer          default(1), not null
#  group_key          :string           not null
#  last_event_at      :datetime         not null
#  next_allowed_at    :datetime
#  notifiable_type    :string           not null
#  payload            :jsonb            not null
#  priority           :enum             default("normal"), not null
#  read_at            :datetime
#  score              :integer          default(0), not null
#  sent_at            :datetime
#  state              :enum             default("queued"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  actor_id           :uuid
#  notifiable_id      :uuid             not null
#  organisation_id    :uuid             not null
#  project_id         :uuid
#  recipient_id       :uuid             not null
#
# Indexes
#
#  idx_notifications_notifiable                    (notifiable_type,notifiable_id)
#  idx_notifications_recipient_state               (recipient_id,state,created_at)
#  idx_notifications_tenant_recipient              (organisation_id,recipient_id,state,created_at)
#  idx_unique_dedupe                               (recipient_id,channel,dedupe_fingerprint) UNIQUE
#  index_notifications_on_actor_id                 (actor_id)
#  index_notifications_on_event_type               (event_type)
#  index_notifications_on_group_key                (group_key)
#  index_notifications_on_notifiable               (notifiable_type,notifiable_id)
#  index_notifications_on_organisation_id          (organisation_id)
#  index_notifications_on_payload                  (payload) USING gin
#  index_notifications_on_project_and_created_at   (project_id,created_at)
#  index_notifications_on_project_id               (project_id)
#  index_notifications_on_recipient_id             (recipient_id)
#  index_notifications_on_recipient_project_state  (recipient_id,project_id,state)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (recipient_id => users.id)
#
FactoryBot.define do
  factory :notification do
    # Basic attributes
    # Let the database generate UUIDs for ids
    event_type { Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE } # Default to system message
    state { 'queued' }
    sequence(:group_key) { |n| "group_key_#{n}" }
    sequence(:dedupe_fingerprint) { |n| "fingerprint_#{n}" }

    # Associations
    association :recipient, factory: :user
    association :organisation
    association :actor, factory: :user

    # Optional associations (can be nil) - but set for basic factory
    association :notifiable, factory: :ticket

    # Payload data
    payload do
      {
        'action' => 'created',
        'message' => 'A new item was created',
        'url' => '/test/url',
        'actor_name' => actor&.full_name || 'System'
      }
    end

    # Timestamps. The event timestamps follow created_at (the model would fill
    # them with Time.current): a factory row created "5 minutes ago" then also
    # had its latest activity 5 minutes ago, which is what the inbox orders by.
    created_at { 1.hour.ago }
    updated_at { 1.hour.ago }
    first_event_at { created_at }
    last_event_at { created_at }
    read_at { state == 'read' ? 30.minutes.ago : nil }

    # Multi-tenant support
    before(:create) do |_notification, evaluator|
      ActsAsTenant.current_tenant ||= evaluator.organisation
    end

    # Variants for different notification types
    trait :unread do
      state { 'queued' }
      read_at { nil }
    end

    trait :read do
      state { 'read' }
      read_at { 30.minutes.ago }
    end

    trait :archived do
      state { 'archived' }
      read_at { 30.minutes.ago }
    end

    # Different event types
    trait :ticket_created do
      # Use a valid event type (legacy 'ticket_created' is not in VALID_EVENT_TYPES)
      event_type { Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE }
      payload do
        {
          'action' => 'created',
          'message' => 'New ticket has been created',
          'object_type' => 'Ticket'
        }
      end
    end

    trait :ticket_updated do
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_STATUS_CHANGED } # Maps to status changed
      payload do
        {
          'action' => 'updated',
          'message' => 'Ticket has been updated',
          'object_type' => 'Ticket'
        }
      end
    end

    trait :ticket_assigned do
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED }
      payload do
        {
          'action' => 'assigned',
          'message' => 'Ticket has been assigned to you',
          'object_type' => 'Ticket'
        }
      end
    end

    trait :ticket_commented do
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED }
      payload do
        {
          'action' => 'commented',
          'message' => 'New comment on ticket',
          'object_type' => 'Comment'
        }
      end
    end

    trait :project_created do
      event_type { Notifications::Constants::EVENT_TYPE_PROJECT_ANNOUNCEMENT } # Maps to project announcement
      payload do
        {
          'action' => 'created',
          'message' => 'New project has been created',
          'object_type' => 'Project'
        }
      end
    end

    trait :time_session_created do
      # Use a valid event type for time session notifications in tests
      event_type { Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE }
      payload do
        {
          'action' => 'created',
          'message' => 'New time session recorded',
          'object_type' => 'TimeSession'
        }
      end
    end

    trait :system_update do
      event_type { Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE }
      actor { nil }
      payload do
        {
          'action' => 'system_notification',
          'message' => 'System maintenance completed',
          'object_type' => 'System'
        }
      end
    end

    # With specific notifiable objects
    trait :with_ticket do
      association :notifiable, factory: :ticket
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED } # Use valid event type
    end

    trait :with_project do
      association :notifiable, factory: :project
      event_type { Notifications::Constants::EVENT_TYPE_PROJECT_ANNOUNCEMENT }
    end

    trait :with_time_session do
      association :notifiable, factory: :time_session
      event_type { Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE }
    end

    trait :with_note do
      association :notifiable, factory: :note
      event_type { Notifications::Constants::EVENT_TYPE_DOCUMENT_ADDED }
    end

    trait :with_comment do
      association :notifiable, factory: :comment
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED }
    end

    # Grouped notifications
    trait :grouped do
      group_key { "ticket_updates_#{SecureRandom.uuid}" }
      group_count { 3 }
      last_event_at { 10.minutes.ago }

      payload do
        {
          'action' => 'multiple_updates',
          'message' => 'Multiple updates on ticket',
          'object_type' => 'Ticket',
          'actor_ids' => [actor&.id, create(:user).id, create(:user).id].compact,
          'group_count' => 3
        }
      end
    end

    # High priority notifications
    trait :high_priority do
      priority { 'high' }
      payload do
        {
          'action' => 'urgent_update',
          'message' => 'Urgent: Critical issue reported',
          'object_type' => 'Ticket',
          'priority' => 'high'
        }
      end
    end

    # Recent notifications
    trait :recent do
      created_at { 5.minutes.ago }
      updated_at { 5.minutes.ago }
    end

    trait :old do
      created_at { 1.week.ago }
      updated_at { 1.week.ago }
    end

    # Batch creation helpers
    trait :batch_unread do
      event_type { Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE }
      state { 'queued' }
      created_at { rand(1..24).hours.ago }
    end

    # For testing different organisations
    trait :for_organisation do
      transient do
        target_organisation { nil }
      end

      organisation { target_organisation }

      before(:create) do |notification, evaluator|
        if evaluator.target_organisation
          ActsAsTenant.with_tenant(evaluator.target_organisation) do
            # Ensure user belongs to the organisation
            notification.recipient.organisations << evaluator.target_organisation unless notification.recipient.organisations.include?(evaluator.target_organisation)
          end
        end
      end
    end

    # Testing edge cases
    trait :without_actor do
      actor { nil }
      payload do
        {
          'action' => 'system_generated',
          'message' => 'System generated notification',
          'actor_name' => 'System'
        }
      end
    end

    trait :without_notifiable do
      notifiable { nil }
      payload do
        {
          'action' => 'general_notification',
          'message' => 'General notification without specific object'
        }
      end
    end

    trait :with_custom_payload do
      transient do
        custom_data { {} }
      end

      payload do
        base_payload = {
          'action' => 'custom',
          'message' => 'Custom notification'
        }
        base_payload.merge(custom_data)
      end
    end
  end

  # NotificationPreference factory
  factory :notification_preference do
    association :user
    association :organisation

    event_type { Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED }
    channel { 'in_app' }
    enabled { true }
    # Frequency is derived from enabled: enabled → immediate, disabled → never
    frequency { 'immediate' }

    # Multi-tenant support
    before(:create) do |_preference, evaluator|
      ActsAsTenant.current_tenant ||= evaluator.organisation
    end

    trait :disabled do
      enabled { false }
    end

    trait :immediate do
      frequency { 'immediate' }
    end

    trait :never do
      frequency { 'never' }
    end

    trait :email_channel do
      channel { 'email' }
    end

    trait :for_mention do
      event_type { Notifications::Constants::EVENT_TYPE_MENTION }
      frequency { 'immediate' } # Default for mentions
    end

    trait :for_status_changed do
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_STATUS_CHANGED }
    end

    trait :for_assignment do
      event_type { Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED }
      frequency { 'immediate' }
    end
  end
end
