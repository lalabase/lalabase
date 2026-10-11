class AddCreatorToDocuments < ActiveRecord::Migration[8.0]
  def change
    add_reference :documents, :creator, null: true, foreign_key: { to_table: :users }, type: :uuid
    
    reversible do |dir|
      dir.up do
        # Set creator for existing documents using organisation admin or any member
        execute <<~SQL
          UPDATE documents 
          SET creator_id = COALESCE(
            (
              SELECT u.id 
              FROM users u
              JOIN memberships m ON m.user_id = u.id
              JOIN roles r ON r.id = m.role_id
              WHERE r.organisation_id = documents.organisation_id 
              AND r.title = 'account_admin'
              AND m.active = true
              LIMIT 1
            ),
            (
              SELECT u.id 
              FROM users u
              JOIN memberships m ON m.user_id = u.id
              WHERE m.organisation_id = documents.organisation_id 
              AND m.active = true
              LIMIT 1
            )
          )
          WHERE creator_id IS NULL
        SQL
      end
    end
    
    change_column_null :documents, :creator_id, false
  end
end
