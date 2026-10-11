class AddMissingForeignKeyIndexes < ActiveRecord::Migration[8.0]
  def change
    # memberships — used on every request for tenant auth
    add_index :memberships, :user_id, if_not_exists: true
    add_index :memberships, :organisation_id, if_not_exists: true
    add_index :memberships, %i[user_id organisation_id], unique: true, if_not_exists: true

    # ticket_assignments — queried on every ticket show/edit
    add_index :ticket_assignments, :ticket_id, if_not_exists: true
    add_index :ticket_assignments, :user_id, if_not_exists: true
    add_index :ticket_assignments, %i[ticket_id user_id], unique: true, if_not_exists: true

    # invitations — token lookup on accept, org scoping
    add_index :invitations, :token, unique: true, if_not_exists: true
    add_index :invitations, :organisation_id, if_not_exists: true

    # document_versions — loaded with every document
    add_index :document_versions, :document_id, if_not_exists: true
    add_index :document_versions, :organisation_id, if_not_exists: true

    # chatposts — loaded for chat history
    add_index :chatposts, :chat_id, if_not_exists: true
    add_index :chatposts, :organisation_id, if_not_exists: true
  end
end
