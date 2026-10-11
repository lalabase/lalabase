class CreateCodebaseUploads < ActiveRecord::Migration[8.0]
  def change
    create_table :codebase_uploads, id: :uuid do |t|
      t.string :codebase_upload_id, null: false
      t.string :file_name, null: false
      t.string :linked_object_type, null: false
      t.string :linked_object_id, null: false
      t.string :file_path
      t.boolean :processed, default: false
      t.uuid :organisation_id, null: false
      t.string :import_session_id, null: false

      t.timestamps
    end
    
    add_foreign_key :codebase_uploads, :organisations
    add_index :codebase_uploads, :organisation_id
    add_index :codebase_uploads, :import_session_id
    add_index :codebase_uploads, [:linked_object_type, :linked_object_id]
    add_index :codebase_uploads, [:codebase_upload_id, :organisation_id]
  end
end
