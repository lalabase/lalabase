class CreateUserActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :user_activities, id: :uuid do |t|
      # Core references
      t.references :user, null: false, foreign_key: true, type: :uuid, index: true
      t.references :organisation, foreign_key: true, type: :uuid, index: true # Optional for multi-org

      # Activity details
      t.string :action, null: false # login, logout, password_reset, etc.
      t.string :category, null: false # auth, profile, permissions, security

      # Request information
      t.string :ip_address
      t.string :user_agent
      t.string :session_id # For session tracking

      # Flexible metadata
      t.jsonb :metadata, default: {} # Additional info depending on action
      t.jsonb :changes, default: {} # On updates: what changed

      # Optional reference to the affected object (e.g. on permission changes)
      t.string :trackable_type
      t.uuid :trackable_id

      # Status and result
      t.string :status, default: 'success' # success, failed, pending
      t.text :failure_reason # On failed: why?
      
      t.timestamps
    end
    
    # Optimized indexes for various query patterns
    add_index :user_activities, [:user_id, :created_at], name: 'idx_user_activities_on_user_and_time'
    add_index :user_activities, [:user_id, :action, :created_at], name: 'idx_user_activities_on_user_action_time'
    add_index :user_activities, [:organisation_id, :created_at], name: 'idx_user_activities_on_org_and_time'
    add_index :user_activities, [:category, :created_at], name: 'idx_user_activities_on_category_and_time'
    add_index :user_activities, [:trackable_type, :trackable_id], name: 'idx_user_activities_on_trackable'
    add_index :user_activities, [:session_id], name: 'idx_user_activities_on_session'
    add_index :user_activities, [:ip_address, :created_at], name: 'idx_user_activities_on_ip_and_time'
    add_index :user_activities, :created_at, name: 'idx_user_activities_on_created_at'
  end
end