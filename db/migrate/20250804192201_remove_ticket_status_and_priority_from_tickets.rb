class RemoveTicketStatusAndPriorityFromTickets < ActiveRecord::Migration[8.0]
  def change
    # Remove foreign key constraints first
    remove_foreign_key :tickets, :ticket_statuses if foreign_key_exists?(:tickets, :ticket_statuses)
    remove_foreign_key :tickets, :ticket_priorities if foreign_key_exists?(:tickets, :ticket_priorities)
    
    # Remove indexes
    remove_index :tickets, :ticket_status_id if index_exists?(:tickets, :ticket_status_id)
    remove_index :tickets, :ticket_priority_id if index_exists?(:tickets, :ticket_priority_id)
    remove_index :tickets, [:project_id, :ticket_status_id] if index_exists?(:tickets, [:project_id, :ticket_status_id])
    remove_index :tickets, [:project_id, :ticket_priority_id] if index_exists?(:tickets, [:project_id, :ticket_priority_id])
    remove_index :tickets, [:project_id, :ticket_status_id, :created_at] if index_exists?(:tickets, [:project_id, :ticket_status_id, :created_at])
    
    # Remove columns
    remove_column :tickets, :ticket_status_id, :uuid
    remove_column :tickets, :ticket_priority_id, :uuid
  end
end
