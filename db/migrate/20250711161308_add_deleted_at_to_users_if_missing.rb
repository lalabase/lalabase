# frozen_string_literal: true

class AddDeletedAtToUsersIfMissing < ActiveRecord::Migration[8.0]
  def up
    # Only add deleted_at column if it doesn't exist
    unless column_exists?(:users, :deleted_at)
      add_column :users, :deleted_at, :datetime
      add_index :users, :deleted_at
      
      # Create partial unique index for active users only
      remove_index :users, :email if index_exists?(:users, :email) && !index_exists?(:users, :email, name: "index_users_on_email_active")
      add_index :users, :email, unique: true, where: "deleted_at IS NULL", name: "index_users_on_email_active" unless index_exists?(:users, :email, name: "index_users_on_email_active")
    end
  end

  def down
    if column_exists?(:users, :deleted_at)
      # Remove partial unique index and restore original
      remove_index :users, name: "index_users_on_email_active" if index_exists?(:users, :email, name: "index_users_on_email_active")
      add_index :users, :email, unique: true unless index_exists?(:users, :email)
      
      # Remove deleted_at index and column
      remove_index :users, :deleted_at if index_exists?(:users, :deleted_at)
      remove_column :users, :deleted_at
    end
  end
end
