class AddNumberToTickets < ActiveRecord::Migration[8.0]
  def up
    # Add the number column
    add_column :tickets, :number, :integer
    
    # Create unique index for project-scoped ticket numbers
    add_index :tickets, [:project_id, :number], unique: true, name: 'index_tickets_on_project_id_and_number'
    
    # Populate existing tickets with numbers
    populate_existing_ticket_numbers
  end
  
  def down
    # Remove the index first
    remove_index :tickets, name: 'index_tickets_on_project_id_and_number' if index_exists?(:tickets, [:project_id, :number], name: 'index_tickets_on_project_id_and_number')
    
    # Remove the column
    remove_column :tickets, :number
  end
  
  private
  
  def populate_existing_ticket_numbers
    # Group tickets by project and assign numbers based on creation order
    execute <<-SQL
      WITH numbered_tickets AS (
        SELECT 
          id,
          ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY created_at ASC) as ticket_number
        FROM tickets
        WHERE number IS NULL
      )
      UPDATE tickets 
      SET number = numbered_tickets.ticket_number
      FROM numbered_tickets
      WHERE tickets.id = numbered_tickets.id;
    SQL
  end
end
