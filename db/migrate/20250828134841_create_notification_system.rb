# frozen_string_literal: true

class CreateNotificationSystem < ActiveRecord::Migration[8.0]
  def change
    # Create PostgreSQL enums for type safety
    create_enum :notification_state, %w[queued sent delivered read archived]
    create_enum :notification_channel, %w[in_app email webhook]
    create_enum :notification_priority, %w[low normal high critical]
    create_enum :notification_frequency, %w[immediate daily weekly never]
    create_enum :notification_event_type, %w[
      ticket_commented ticket_assigned ticket_status_changed
      ticket_blocker project_announcement document_added 
      mention system_message
    ]

    # Main notifications table
    create_table :notifications, id: :uuid do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.references :recipient, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :actor, foreign_key: { to_table: :users }, type: :uuid
      t.references :notifiable, polymorphic: true, null: false, type: :uuid
      
      t.enum :event_type, enum_type: :notification_event_type, null: false
      t.enum :channel, enum_type: :notification_channel, null: false, default: 'in_app'
      t.enum :priority, enum_type: :notification_priority, null: false, default: 'normal'
      t.enum :state, enum_type: :notification_state, null: false, default: 'queued'

      t.string :group_key, null: false
      t.integer :group_count, null: false, default: 1
      t.datetime :first_event_at, null: false
      t.datetime :last_event_at, null: false

      t.integer :score, null: false, default: 0
      t.string :dedupe_fingerprint, null: false
      t.jsonb :payload, null: false, default: {}

      t.datetime :read_at
      t.datetime :archived_at
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :next_allowed_at # for quiet hours/rate limiting

      t.timestamps
    end

    # Performance indexes
    add_index :notifications, [:recipient_id, :state, :created_at], 
              name: 'idx_notifications_recipient_state'
    add_index :notifications, [:organisation_id, :recipient_id, :state, :created_at], 
              name: 'idx_notifications_tenant_recipient'
    add_index :notifications, :group_key
    add_index :notifications, :event_type
    add_index :notifications, :payload, using: :gin
    add_index :notifications, [:recipient_id, :channel, :dedupe_fingerprint], 
              unique: true, name: 'idx_unique_dedupe'
    add_index :notifications, [:notifiable_type, :notifiable_id], 
              name: 'idx_notifications_notifiable'

    # User notification preferences
    create_table :notification_preferences, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :organisation, foreign_key: true, type: :uuid
      
      t.string :scope_type # nil for global, or 'Project' etc
      t.uuid :scope_id     # nil for global, or specific project ID
      
      t.enum :event_type, enum_type: :notification_event_type, null: false
      t.enum :channel, enum_type: :notification_channel, null: false
      t.enum :frequency, enum_type: :notification_frequency, null: false, default: 'daily'
      
      t.boolean :enabled, null: false, default: true
      t.string :timezone, default: 'Europe/Berlin'
      t.jsonb :quiet_hours, null: false, default: {} # {start: "22:00", end: "07:30"}
      
      t.timestamps
    end

    add_index :notification_preferences, 
              [:user_id, :organisation_id, :scope_type, :scope_id, :event_type, :channel], 
              unique: true, 
              name: 'idx_pref_uniqueness'
    add_index :notification_preferences, [:user_id, :event_type, :channel],
              name: 'idx_pref_lookup'

    # Notification subscriptions (follow/watch specific items)
    create_enum :subscription_mode, %w[follow mute immediate]
    
    create_table :notification_subscriptions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      
      t.string :subscribable_type, null: false # 'Ticket', 'Project', etc
      t.uuid :subscribable_id, null: false
      
      t.enum :mode, enum_type: :subscription_mode, null: false, default: 'follow'
      
      t.timestamps
    end

    add_index :notification_subscriptions, 
              [:user_id, :subscribable_type, :subscribable_id], 
              unique: true, 
              name: 'idx_subscription_uniqueness'
    add_index :notification_subscriptions,
              [:subscribable_type, :subscribable_id],
              name: 'idx_subscription_lookup'

    # Transactional outbox for reliable notification generation
    create_table :outbox_events, id: :uuid do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.references :activity, null: false, foreign_key: true, type: :uuid
      
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      
      t.datetime :available_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.datetime :processed_at
      t.integer :retry_count, default: 0
      t.string :error_message
      
      t.timestamps
    end

    add_index :outbox_events, [:available_at, :processed_at], 
              name: 'idx_outbox_processing'
    # activity_id index is automatically created by references

    # Email delivery logs (for tracking and debugging)
    create_table :email_logs, id: :uuid do |t|
      t.references :notification, null: false, foreign_key: true, type: :uuid
      
      t.string :provider_message_id
      t.integer :status, null: false, default: 0 # 0=queued, 1=sent, 2=bounced, 3=complaint, 4=opened, 5=clicked
      t.jsonb :metadata, null: false, default: {}
      
      t.timestamps
    end

    add_index :email_logs, :provider_message_id
    add_index :email_logs, [:notification_id, :status]
  end
end
