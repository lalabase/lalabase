class CreateSmartFolderRuleGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :smart_folder_rule_groups, id: :uuid do |t|
      t.references :smart_folder, type: :uuid, null: false, foreign_key: true
      t.string :name
      t.integer :position, null: false, default: 1
      
      t.timestamps
    end
    
    # Index for faster sorting
    add_index :smart_folder_rule_groups, [:smart_folder_id, :position]
  end
end
