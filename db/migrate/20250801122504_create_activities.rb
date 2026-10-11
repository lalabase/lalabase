# frozen_string_literal: true

class CreateActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :activities, id: :uuid do |t|
      # Who performed the action
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users }
      
      # Multi-Tenancy
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      
      # What the Activity refers to (polymorphic)
      t.references :trackable, type: :uuid, polymorphic: true, null: false
      
      # Optional secondary reference (e.g. Post for ticket.posts.create)
      t.references :secondary, type: :uuid, polymorphic: true, null: true
      
      # Activity type
      t.string :action, null: false # 'created', 'updated', 'assigned', etc.
      t.string :key, null: false # 'ticket.created', 'ticket.status_changed', etc.
      
      # Flexible data
      t.jsonb :parameters, default: {} # Additional metadata
      t.jsonb :attribute_changes, default: {} # On updates: what has changed
      
      t.timestamps
      
      # Indexes for performance
      # User activity stream
      t.index [:actor_id, :created_at], name: 'index_activities_on_actor_and_time'
      
      # Object timeline (e.g. all Activities of a ticket)
      t.index [:trackable_type, :trackable_id, :created_at], 
              name: 'index_activities_on_trackable_and_time'
      
      # Organisation-wide queries with filter
      t.index [:organisation_id, :key, :created_at], 
              name: 'index_activities_on_org_key_and_time'
      
      # For queries by specific actions
      t.index [:organisation_id, :action, :created_at],
              name: 'index_activities_on_org_action_and_time'
              
      # Secondary lookups (e.g. all Activities for a Post)
      t.index [:secondary_type, :secondary_id],
              name: 'index_activities_on_secondary_ref'
    end
  end
end