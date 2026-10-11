class CreateSmartFolderRules < ActiveRecord::Migration[8.0]
  def change
    create_table :smart_folder_rules, id: :uuid do |t|
      t.references :smart_folder_rule_group, type: :uuid, null: false, foreign_key: true
      t.string :field, null: false
      t.string :operator, null: false
      t.text :value
      t.text :display_value
      t.integer :position, null: false, default: 1
      t.jsonb :config, default: {}
      
      t.timestamps
    end
    
    # Optimized indexes for performance and filtering
    add_index :smart_folder_rules, [:smart_folder_rule_group_id, :position]
    add_index :smart_folder_rules, [:field, :operator]
    add_index :smart_folder_rules, :config, using: :gin
  end
end
