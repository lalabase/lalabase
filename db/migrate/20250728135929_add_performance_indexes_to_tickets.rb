class AddPerformanceIndexesToTickets < ActiveRecord::Migration[8.0]
  def change
    # === TICKETS TABLE INDEXES ===
    
    # Core listing and filtering indexes
    add_index :tickets, [:project_id, :created_at], 
              name: 'index_tickets_on_project_created', 
              comment: 'For ticket listing sorted by creation date'
    
    add_index :tickets, [:project_id, :updated_at], 
              name: 'index_tickets_on_project_updated',
              comment: 'For ticket listing sorted by update date'
    
    # Status and priority filtering (very common queries)
    add_index :tickets, [:project_id, :ticket_status_id], 
              name: 'index_tickets_on_project_status',
              comment: 'For filtering by status within project'
    
    add_index :tickets, [:project_id, :ticket_priority_id], 
              name: 'index_tickets_on_project_priority',
              comment: 'For filtering by priority within project'
    
    # Combined filter index for complex queries
    add_index :tickets, [:project_id, :ticket_status_id, :created_at], 
              name: 'index_tickets_on_project_status_created',
              comment: 'For status filtering with date sorting'
    
    # Creator/assignment queries
    add_index :tickets, [:project_id, :creator_id], 
              name: 'index_tickets_on_project_creator',
              comment: 'For filtering by creator within project'
    
    # Text search optimization (if using pg_search or similar)
    add_index :tickets, [:project_id, :title], 
              name: 'index_tickets_on_project_title',
              comment: 'For title-based searches within project'
    
    # Organisation-level queries (for admin views)
    add_index :tickets, [:organisation_id, :created_at], 
              name: 'index_tickets_on_org_created',
              comment: 'For organisation-wide ticket views'
    
    # === POSTS TABLE INDEXES ===
    
    # Timeline queries - most important for ticket detail views
    add_index :posts, [:ticket_id, :created_at], 
              name: 'index_posts_on_ticket_created',
              comment: 'For loading ticket timeline chronologically'
    
    # User activity queries
    add_index :posts, [:user_id, :created_at], 
              name: 'index_posts_on_user_created',
              comment: 'For user activity views'
    
    # Privacy-aware queries (building on existing privacy index)
    add_index :posts, [:ticket_id, :is_private, :created_at], 
              name: 'index_posts_on_ticket_privacy_created',
              comment: 'For timeline with privacy filtering'
    
    # === TIME_SESSIONS TABLE INDEXES ===
    
    # Timeline queries for ticket detail views
    add_index :time_sessions, [:ticket_id, :occurred_on], 
              name: 'index_time_sessions_on_ticket_occurred',
              comment: 'For loading ticket time sessions chronologically'
    
    # Project-level time tracking queries
    add_index :time_sessions, [:project_id, :occurred_on], 
              name: 'index_time_sessions_on_project_occurred',
              comment: 'For project time tracking views'
    
    # Billing queries
    add_index :time_sessions, [:project_id, :billed_at], 
              name: 'index_time_sessions_on_project_billed',
              comment: 'For billing status queries'
    
    # Soft delete optimization (building on existing deleted_at index)
    add_index :time_sessions, [:deleted_at, :project_id, :occurred_on], 
              name: 'index_time_sessions_active_project_occurred',
              comment: 'For active time sessions in project chronologically'
    
    # === TAGS AND TAGGINGS OPTIMIZATION ===
    
    # Check if taggings table exists and add indexes
    if table_exists?(:taggings)
      # Most common tagging queries
      add_index :taggings, [:taggable_type, :taggable_id, :tag_id], 
                name: 'index_taggings_on_taggable_and_tag',
                comment: 'For loading tags for specific objects'
      
      # Tag-based filtering
      add_index :taggings, [:tag_id, :taggable_type], 
                name: 'index_taggings_on_tag_and_type',
                comment: 'For finding objects with specific tags'
    end
    
    # === FOREIGN KEY PERFORMANCE ===
    
    # Ensure all foreign keys have indexes (Rails usually creates these, but double-check)
    add_index :tickets, :ticket_status_id, 
              if_not_exists: true,
              comment: 'Foreign key index for ticket statuses'
    
    add_index :tickets, :ticket_priority_id, 
              if_not_exists: true,
              comment: 'Foreign key index for ticket priorities'
    
    add_index :tickets, :creator_id, 
              if_not_exists: true,
              comment: 'Foreign key index for creators'
    
    add_index :posts, :user_id, 
              if_not_exists: true,
              comment: 'Foreign key index for post users'
    
    add_index :time_sessions, :ticket_id, 
              if_not_exists: true,
              comment: 'Foreign key index for time session tickets'
  end
end
