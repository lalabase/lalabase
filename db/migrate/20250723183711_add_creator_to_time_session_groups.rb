class AddCreatorToTimeSessionGroups < ActiveRecord::Migration[8.0]
  def change
    add_reference :time_session_groups, :creator, type: :uuid, foreign_key: { to_table: :users }
    
    # Set existing records to have the first admin as creator
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE time_session_groups
          SET creator_id = (
            SELECT users.id 
            FROM users 
            JOIN memberships ON users.id = memberships.user_id
            WHERE memberships.organisation_id = time_session_groups.organisation_id
            AND memberships.role = 'admin'
            AND users.deleted_at IS NULL
            ORDER BY users.created_at
            LIMIT 1
          )
          WHERE creator_id IS NULL;
        SQL
        
        # Make creator_id NOT NULL after populating
        change_column_null :time_session_groups, :creator_id, false
      end
    end
  end
end
