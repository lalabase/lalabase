# frozen_string_literal: true

class CreateDocumentationPages < ActiveRecord::Migration[8.0]
  def change
    create_table :documentation_pages, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :documentation_set, type: :uuid, null: false, foreign_key: true
      # Path relative to the set's path_prefix, e.g. "guide/intro.md".
      t.string :path, null: false
      t.string :title
      t.text :markdown_body
      # Cached sanitized HTML produced during sync.
      t.text :rendered_html
      # Git blob SHA of the source file, for incremental re-embedding (later slice).
      t.string :git_blob_sha, null: false
      # Soft-removal marker when the source file disappears from the repo.
      t.datetime :removed_at
      t.timestamps
    end

    add_index :documentation_pages, %i[documentation_set_id path],
              unique: true, name: 'idx_documentation_pages_set_path'
    add_index :documentation_pages, %i[documentation_set_id removed_at]
  end
end
