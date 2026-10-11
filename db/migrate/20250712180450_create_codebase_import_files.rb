class CreateCodebaseImportFiles < ActiveRecord::Migration[8.0]
  def change
    create_table :codebase_import_files, id: :uuid do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid  # The admin who uploads
      t.string :file_type, null: false  # 'users', 'tickets', 'time_tracking'
      t.string :original_filename
      t.text :file_content  # XML content as text
      t.integer :file_size
      t.string :status, default: 'uploaded'  # uploaded, processing, processed, error
      t.json :metadata, default: {}  # For additional information
      t.datetime :processed_at
      t.timestamps
    end

    add_index :codebase_import_files, [:organisation_id, :file_type]
    add_index :codebase_import_files, :status
  end
end