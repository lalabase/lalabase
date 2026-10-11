# frozen_string_literal: true

class CreateDocumentationCommits < ActiveRecord::Migration[8.0]
  def change
    create_table :documentation_commits, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :documentation_set, type: :uuid, null: false, foreign_key: true
      t.string :commit_sha, null: false
      t.string :author_name
      # Commit subject line (git %s) — the logbook shows WHAT changed, not diffs.
      t.string :message
      t.datetime :committed_at, null: false
      t.timestamps
    end

    add_index :documentation_commits, %i[documentation_set_id commit_sha],
              unique: true, name: 'idx_documentation_commits_set_sha'
    add_index :documentation_commits, %i[documentation_set_id committed_at],
              name: 'idx_documentation_commits_set_time'
  end
end
