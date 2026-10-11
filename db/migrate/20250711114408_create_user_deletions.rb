class CreateUserDeletions < ActiveRecord::Migration[8.0]
  def up
    create_table :user_deletions, id: :uuid do |t|
      t.uuid :deleted_user_id, null: false
      t.string :deleter_type, null: false  # 'User' or 'Beuser'
      t.uuid :deleter_id, null: false
      t.string :source, null: false  # 'selfservice' or 'backend'
      t.text :reason
      t.datetime :deleted_at, null: false

      # Add indexes for performance
      t.index :deleted_user_id
      t.index [:deleter_type, :deleter_id]
      t.index :source
      t.index :deleted_at

      t.timestamps
    end

    # Add foreign key constraint
    add_foreign_key :user_deletions, :users, column: :deleted_user_id
  end

  def down
    # Remove foreign key constraint first
    remove_foreign_key :user_deletions, :users if foreign_key_exists?(:user_deletions, :users, column: :deleted_user_id)
    
    # Drop the table
    drop_table :user_deletions if table_exists?(:user_deletions)
  end
end
