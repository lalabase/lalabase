class FixAllSolidQueueForeignKeys < ActiveRecord::Migration[8.0]
  def up
    # Fix process_id in solid_queue_claimed_executions
    if column_exists?(:solid_queue_claimed_executions, :process_id)
      # Remove foreign key if exists
      if foreign_key_exists?(:solid_queue_claimed_executions, column: :process_id)
        remove_foreign_key :solid_queue_claimed_executions, column: :process_id
      end
      
      # Remove and recreate the column as uuid
      remove_column :solid_queue_claimed_executions, :process_id
      add_column :solid_queue_claimed_executions, :process_id, :uuid
      
      # Re-add index
      add_index :solid_queue_claimed_executions, [:process_id, :job_id]
      
      # Add foreign key to solid_queue_processes
      add_foreign_key :solid_queue_claimed_executions, :solid_queue_processes, 
                      column: :process_id, on_delete: :nullify
    end
  end
  
  def down
    if column_exists?(:solid_queue_claimed_executions, :process_id)
      if foreign_key_exists?(:solid_queue_claimed_executions, column: :process_id)
        remove_foreign_key :solid_queue_claimed_executions, column: :process_id
      end
      
      remove_column :solid_queue_claimed_executions, :process_id
      add_column :solid_queue_claimed_executions, :process_id, :bigint
      add_index :solid_queue_claimed_executions, [:process_id, :job_id]
    end
  end
end