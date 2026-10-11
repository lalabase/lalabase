class AddMissingTenantAndProjectIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    # Critical: most-used relationships without an index
    add_index :projects, :organisation_id, algorithm: :concurrently, if_not_exists: true
    add_index :notes, :organisation_id, algorithm: :concurrently, if_not_exists: true
    add_index :notes, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :chats, :organisation_id, algorithm: :concurrently, if_not_exists: true
    add_index :chats, :project_id, algorithm: :concurrently, if_not_exists: true

    # Secondary: less frequently used but also missing
    add_index :posts, :organisation_id, algorithm: :concurrently, if_not_exists: true
    add_index :ticket_documents, :organisation_id, algorithm: :concurrently, if_not_exists: true
    add_index :post_documents, :organisation_id, algorithm: :concurrently, if_not_exists: true
  end
end
