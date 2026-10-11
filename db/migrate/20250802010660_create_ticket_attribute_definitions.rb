class CreateTicketAttributeDefinitions < ActiveRecord::Migration[8.0]
  def change
    create_table :ticket_attribute_definitions, id: :uuid do |t|
      t.references :attribute_group, null: false, foreign_key: true, type: :uuid
      
      # Basic fields
      t.string :name, null: false # Internal identifier (e.g., 'deal_value')
      t.string :field_type, null: false # text, select, number, date, etc.
      
      # Multilingual labels
      t.jsonb :labels, default: {} # {"de": "Deal-Wert", "en": "Deal Value"}
      
      # Configuration and options
      t.jsonb :options, default: {} # For select: allowed_values, for number: min/max, etc.
      t.jsonb :validation_rules, default: {} # {"required": true, "min": 0}
      t.jsonb :visibility_rules, default: {} # {"ticket_type": "deal"}
      
      # UI configuration
      t.integer :position, default: 0
      t.string :section # For grouping in forms
      t.string :width, default: 'full' # full, half, third
      
      # Metadata
      t.boolean :active, default: true
      t.boolean :system, default: false # System fields can't be deleted
      
      t.timestamps
    end
    
    add_index :ticket_attribute_definitions, [:attribute_group_id, :name], unique: true
    add_index :ticket_attribute_definitions, [:attribute_group_id, :active]
    add_index :ticket_attribute_definitions, :position
  end
end