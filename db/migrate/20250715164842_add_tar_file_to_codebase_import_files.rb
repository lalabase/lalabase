class AddTarFileToCodebaseImportFiles < ActiveRecord::Migration[8.0]
  def change
    add_column :codebase_import_files, :tar_file_content, :binary
    add_column :codebase_import_files, :tar_file_size, :integer
    add_column :codebase_import_files, :tar_original_filename, :string
  end
end
