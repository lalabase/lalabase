class CreateSmartFolderShares < ActiveRecord::Migration[8.0]
  def change
    create_table :smart_folder_shares, id: :uuid do |t|
      t.references :smart_folder, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.boolean :can_edit, default: false
      t.boolean :can_share, default: false
      
      t.timestamps
    end
    
    # Unique index for user and folder
    add_index :smart_folder_shares, [:smart_folder_id, :user_id], unique: true
  end
end
