class CreateSmartFolders < ActiveRecord::Migration[8.0]
  def change
    create_table :smart_folders, id: :uuid do |t|
      t.string :name, null: false
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, foreign_key: true
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.integer :sort_by, default: 0
      t.integer :color_code
      t.integer :position
      t.text :description
      t.boolean :is_public, default: false
      t.integer :public_access_level, default: 0
      
      t.timestamps
    end
    
    # Optimized indexes for frequent queries
    add_index :smart_folders, [:organisation_id, :user_id]
    add_index :smart_folders, [:organisation_id, :project_id]
    add_index :smart_folders, [:organisation_id, :is_public]
  end
end
