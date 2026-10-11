# =============================================================================
# Migration: Add Active Status to Users
# =============================================================================
# This migration adds an 'active' boolean column to the users table to enable
# admin users to activate/deactivate user accounts.
# 
# Purpose:
# - Allow administrators to disable user accounts without deleting them
# - Maintain user data and relationships while preventing login access
# - Provide audit trail of user status changes
# 
# Schema Changes:
# - Adds 'active' column with boolean type
# - Sets default value to true (all users active by default) 
# - Prevents null values for data consistency
# 
# Data Migration:
# - Sets all existing users to active status (backwards compatibility)
# - Ensures no user accounts are accidentally disabled during migration
# =============================================================================

class AddActiveToUsers < ActiveRecord::Migration[8.0]
  def change
    # Add active status column to users table
    # Default: true (active) - new users are active by default
    # NOT NULL constraint ensures data consistency
    add_column :users, :active, :boolean, default: true, null: false
    
    # Data migration: Set all existing users to active status
    # This ensures backwards compatibility - no existing users are accidentally disabled
    # Note: This runs as part of the schema change, not as a separate data migration
    User.update_all(active: true)
  end
end
