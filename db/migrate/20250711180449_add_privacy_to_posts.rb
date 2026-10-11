class AddPrivacyToPosts < ActiveRecord::Migration[8.0]
  def up
    # Add private flag with default false
    add_column :posts, :is_private, :boolean, default: false, null: false
    
    # Add reference to user who can see the private post (optional, only for private posts)
    add_reference :posts, :visible_to_user, null: true, foreign_key: { to_table: :users }, type: :uuid
    
    # Add index for performance when filtering private posts
    add_index :posts, [:is_private, :visible_to_user_id], name: 'index_posts_on_privacy'
    add_index :posts, [:ticket_id, :is_private], name: 'index_posts_on_ticket_and_privacy'
  end
  
  def down
    remove_index :posts, name: 'index_posts_on_privacy' if index_exists?(:posts, [:is_private, :visible_to_user_id], name: 'index_posts_on_privacy')
    remove_index :posts, name: 'index_posts_on_ticket_and_privacy' if index_exists?(:posts, [:ticket_id, :is_private], name: 'index_posts_on_ticket_and_privacy')
    
    remove_reference :posts, :visible_to_user, foreign_key: { to_table: :users }, type: :uuid if column_exists?(:posts, :visible_to_user_id)
    remove_column :posts, :is_private if column_exists?(:posts, :is_private)
  end
end
