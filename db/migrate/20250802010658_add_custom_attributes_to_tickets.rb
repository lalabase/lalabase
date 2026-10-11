class AddCustomAttributesToTickets < ActiveRecord::Migration[8.0]
  def change
    # JSONB column for storing custom attribute values
    add_column :tickets, :custom_attributes, :jsonb, default: {}, null: false
    
    # Add GIN index for efficient JSONB queries
    add_index :tickets, :custom_attributes, using: :gin
    
    # Add ticket_type to distinguish between support tickets and CRM deals
    add_column :tickets, :ticket_type, :string, default: 'support', null: false
    add_index :tickets, :ticket_type
    
    # Index for common queries
    add_index :tickets, [:organisation_id, :ticket_type]
  end
end