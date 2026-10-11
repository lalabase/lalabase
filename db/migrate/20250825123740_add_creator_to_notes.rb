class AddCreatorToNotes < ActiveRecord::Migration[8.0]
  def change
    # First add the column as nullable
    add_reference :notes, :creator, null: true, foreign_key: { to_table: :users }, type: :uuid
    
    # Set creator for existing notes (use first available user as fallback)
    reversible do |dir|
      dir.up do
        # First try admin users, then any user from the organisation
        execute <<~SQL
          UPDATE notes 
          SET creator_id = COALESCE(
            (
              SELECT u.id 
              FROM users u
              JOIN memberships m ON m.user_id = u.id
              JOIN roles r ON r.id = m.role_id
              WHERE r.organisation_id = notes.organisation_id 
              AND r.title = 'account_admin'
              AND m.active = true
              LIMIT 1
            ),
            (
              SELECT u.id 
              FROM users u
              JOIN memberships m ON m.user_id = u.id
              WHERE m.organisation_id = notes.organisation_id 
              AND m.active = true
              LIMIT 1
            )
          )
          WHERE creator_id IS NULL
        SQL
      end
    end
    
    # Make the column non-nullable
    change_column_null :notes, :creator_id, false
  end
end
