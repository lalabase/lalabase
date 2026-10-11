class RemoveArchiveFieldsFromCodebaseImportFiles < ActiveRecord::Migration[8.0]
  def change
    remove_column :codebase_import_files, :tar_file_content, :binary
    remove_column :codebase_import_files, :tar_file_size, :integer
    remove_column :codebase_import_files, :tar_original_filename, :string
  end
end
