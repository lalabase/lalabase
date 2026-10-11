class AddProcessingFieldsToCodebaseImportFiles < ActiveRecord::Migration[8.0]
  def up
    # Only add the columns if they do not already exist
    unless column_exists?(:codebase_import_files, :processing_started_at)
      add_column :codebase_import_files, :processing_started_at, :datetime
    end
    
    unless column_exists?(:codebase_import_files, :processing_completed_at)
      add_column :codebase_import_files, :processing_completed_at, :datetime
    end
    
    unless column_exists?(:codebase_import_files, :error_message)
      add_column :codebase_import_files, :error_message, :text
    end
    
    unless column_exists?(:codebase_import_files, :import_summary)
      add_column :codebase_import_files, :import_summary, :json
    end
  end
  
  def down
    remove_column :codebase_import_files, :processing_started_at if column_exists?(:codebase_import_files, :processing_started_at)
    remove_column :codebase_import_files, :processing_completed_at if column_exists?(:codebase_import_files, :processing_completed_at)
    remove_column :codebase_import_files, :error_message if column_exists?(:codebase_import_files, :error_message)
    remove_column :codebase_import_files, :import_summary if column_exists?(:codebase_import_files, :import_summary)
  end
end