class CreateCodebaseImportMappings < ActiveRecord::Migration[8.0]
  def change
    create_table :codebase_import_mappings, id: :uuid do |t|
      t.string :codebase_id, null: false # Original ID from CodebaseHQ
      t.uuid :local_id, null: false # ID in LalaBase
      t.string :entity_type, null: false # 'User', 'Ticket', etc.
      t.json :mapping_data, default: {} # Additional mapping information
      t.timestamps
    end

    add_index :codebase_import_mappings, [:codebase_id, :entity_type], unique: true
    add_index :codebase_import_mappings, [:local_id, :entity_type]
    add_index :codebase_import_mappings, :entity_type
  end
end