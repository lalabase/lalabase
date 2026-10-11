class AddBilledToTimeSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :time_sessions, :billed, :boolean, default: false, null: false
    add_index :time_sessions, :billed
    
    # Datenmigration: Setze billed Status basierend auf TimeSessionGroup
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE time_sessions 
          SET billed = true 
          WHERE time_session_group_id IN (
            SELECT id FROM time_session_groups WHERE billed = true
          )
        SQL
      end
    end
  end
end
