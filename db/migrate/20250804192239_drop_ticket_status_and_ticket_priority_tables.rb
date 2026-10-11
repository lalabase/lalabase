class DropTicketStatusAndTicketPriorityTables < ActiveRecord::Migration[8.0]
  def change
    drop_table :ticket_statuses
    drop_table :ticket_priorities
  end
end
