# frozen_string_literal: true

# The images of a synced documentation set, copied from the repository at sync time and
# served by the instance. Until now a page showed them
# from raw.githubusercontent.com: every reader contacted GitHub, and a private
# repository's images did not show at all.
#
# One row per set and repository path. The file itself is an Active Storage attachment;
# the row carries what decides whether it has to be uploaded again (git_blob_sha) and
# what the type is according to its bytes (content_type), not according to its name.
#
# The id is what the cached page HTML points at, so the row is upserted, never replaced.
#
# The two counters on a sync run say how many images a run kept and how many it turned
# down (too large, not an image, outside the repository, one too many).
class CreateDocumentationAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :documentation_assets, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :documentation_set, type: :uuid, null: false, index: false, foreign_key: true
      t.string :path, null: false
      t.string :git_blob_sha, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.timestamps
    end

    add_index :documentation_assets, %i[documentation_set_id path],
              unique: true, name: 'idx_documentation_assets_set_path'

    change_table :documentation_sync_runs, bulk: true do |t|
      t.integer :assets_synced, default: 0, null: false
      t.integer :assets_skipped, default: 0, null: false
    end
  end
end
