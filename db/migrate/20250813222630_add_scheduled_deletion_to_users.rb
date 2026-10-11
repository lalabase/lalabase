class AddScheduledDeletionToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :scheduled_deletion_at, :datetime
    add_column :users, :deletion_canceled_at, :datetime
    add_column :users, :deletion_reason, :text
    
    add_index :users, :scheduled_deletion_at
    
    # Also extend the UserDeletions table
    add_column :user_deletions, :scheduled_at, :datetime
    add_column :user_deletions, :executed_at, :datetime
    add_column :user_deletions, :canceled_at, :datetime
    add_column :user_deletions, :cancellation_reason, :text
  end
end
