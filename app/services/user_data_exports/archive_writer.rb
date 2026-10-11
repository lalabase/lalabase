# frozen_string_literal: true

require 'zip'

module UserDataExports
  # Writes the Builder's file map into a ZIP on disk. Separated from the
  # Builder so the org export (doc/org_data_export_plan.md) can reuse the ZIP
  # mechanics with a different file map.
  class ArchiveWriter
    def self.write(files, into_dir:)
      zip_path = File.join(into_dir, 'export.zip')
      Zip::File.open(zip_path, create: true) do |zip|
        files.each do |path, content|
          zip.get_output_stream(path) { |io| io.write(content) }
        end
      end
      zip_path
    end
  end
end
