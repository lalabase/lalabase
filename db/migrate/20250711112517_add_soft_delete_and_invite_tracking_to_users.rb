class AddSoftDeleteAndInviteTrackingToUsers < ActiveRecord::Migration[8.0]
  def up
    # Add only missing columns (deleted_at already exists)
    add_column :users, :deletion_recommended, :boolean, default: false, null: false
    add_column :users, :invited_by_user_id, :uuid
    add_column :users, :invited_by_org_id, :uuid

    # Add indexes for performance (deleted_at index already exists)
    add_index :users, :deletion_recommended
    add_index :users, :invited_by_user_id
    add_index :users, :invited_by_org_id

    # Add foreign key constraints for invite tracking
    add_foreign_key :users, :users, column: :invited_by_user_id
    add_foreign_key :users, :organisations, column: :invited_by_org_id

    # Partial unique index for active users already exists, no need to recreate
  end

  def down
    # Remove foreign key constraints first
    remove_foreign_key :users, :users if foreign_key_exists?(:users, :users, column: :invited_by_user_id)
    remove_foreign_key :users, :organisations if foreign_key_exists?(:users, :organisations, column: :invited_by_org_id)

    # Remove indexes (only the ones we added)
    remove_index :users, :deletion_recommended if index_exists?(:users, :deletion_recommended)
    remove_index :users, :invited_by_user_id if index_exists?(:users, :invited_by_user_id)
    remove_index :users, :invited_by_org_id if index_exists?(:users, :invited_by_org_id)

    # Remove only the columns we added (deleted_at remains)
    remove_column :users, :deletion_recommended
    remove_column :users, :invited_by_user_id
    remove_column :users, :invited_by_org_id
  end
end
