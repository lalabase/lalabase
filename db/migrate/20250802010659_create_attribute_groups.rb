class CreateAttributeGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :attribute_groups, id: :uuid do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      
      # Basic fields
      t.string :name, null: false # e.g., "Ticketsystem", "CRM", "Support"
      t.text :description
      
      # Configuration
      t.jsonb :settings, default: {} # For future extensibility
      t.string :icon # Optional icon for UI
      t.string :color # Optional color for UI
      
      # Control
      t.boolean :active, default: true
      t.boolean :system, default: false # System groups can't be deleted
      t.integer :position, default: 0
      
      t.timestamps
    end
    
    add_index :attribute_groups, [:organisation_id, :name], unique: true
    add_index :attribute_groups, [:organisation_id, :active]
    add_index :attribute_groups, :position
  end
end