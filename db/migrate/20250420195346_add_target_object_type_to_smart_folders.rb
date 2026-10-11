class AddTargetObjectTypeToSmartFolders < ActiveRecord::Migration[8.0]
  def change
    add_column :smart_folders, :target_object_type, :string, default: 'Note'
    
    # Add index for faster queries
    add_index :smart_folders, [:organisation_id, :target_object_type]
    
    # Set values for existing SmartFolders
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE smart_folders SET target_object_type = 'Note' WHERE target_object_type IS NULL;
        SQL
      end
    end
  end
end
