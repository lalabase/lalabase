class FixSolidQueueSupervisorIdType < ActiveRecord::Migration[8.0]
  def up
    # Since we can't directly cast bigint to uuid and the table is likely empty,
    # we'll drop and recreate the column
    
    # Only proceed if the column exists and is the wrong type
    if column_exists?(:solid_queue_processes, :supervisor_id)
      current_type = columns(:solid_queue_processes).find { |c| c.name == 'supervisor_id' }&.sql_type
      
      # Only migrate if it's not already uuid
      if current_type != 'uuid'
        # Remove the foreign key constraint if it exists
        if foreign_key_exists?(:solid_queue_processes, column: :supervisor_id)
          remove_foreign_key :solid_queue_processes, column: :supervisor_id
        end
        
        # Remove the old column
        remove_column :solid_queue_processes, :supervisor_id
      end
    end
    
    # Add the column if it doesn't exist
    unless column_exists?(:solid_queue_processes, :supervisor_id)
      add_column :solid_queue_processes, :supervisor_id, :uuid
    end
    
    # Re-add the index if it doesn't exist
    unless index_exists?(:solid_queue_processes, :supervisor_id)
      add_index :solid_queue_processes, :supervisor_id
    end
    
    # Re-add the self-referential foreign key if needed
    unless foreign_key_exists?(:solid_queue_processes, column: :supervisor_id)
      add_foreign_key :solid_queue_processes, :solid_queue_processes, 
                      column: :supervisor_id, primary_key: :id, on_delete: :nullify
    end
  end
  
  def down
    if foreign_key_exists?(:solid_queue_processes, column: :supervisor_id)
      remove_foreign_key :solid_queue_processes, column: :supervisor_id
    end
    
    remove_column :solid_queue_processes, :supervisor_id
    add_column :solid_queue_processes, :supervisor_id, :bigint
    add_index :solid_queue_processes, :supervisor_id
  end
end