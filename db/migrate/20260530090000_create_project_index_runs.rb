# frozen_string_literal: true

# Run history of the indexing: one row per actually performed run
# (full index + incremental push reindex), success as well as failure. The current
# ProjectIndex state is overwritten on every run — this table is the
# missing history ("when/what/how long was re-indexed").
class CreateProjectIndexRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :project_index_runs, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      # index: false — the composite index below covers project_repository_id as
      # the leftmost prefix, an additional single-column index would be redundant.
      t.references :project_repository, type: :uuid, null: false, foreign_key: true, index: false
      # on_delete: :nullify — the run history should survive a deleted trigger
      # (column nullable + belongs_to optional). RESTRICT (PG default)
      # would instead block deleting the user; nullify is also the
      # precedent set by the chats FK.
      t.references :triggered_by_user, type: :uuid, null: true,
                                       foreign_key: { to_table: :users, on_delete: :nullify }

      t.string  :trigger, null: false               # initial | manual | push
      t.string  :status,  null: false               # ready | failed
      t.boolean :incremental, null: false, default: false

      t.datetime :started_at,  null: false
      t.datetime :finished_at, null: false

      t.string  :commit_sha
      t.integer :files_count,     null: false, default: 0
      t.integer :symbols_added,   null: false, default: 0
      t.integer :symbols_removed, null: false, default: 0
      t.text    :error_message

      t.timestamps
    end

    # Access pattern: the most recent runs of ONE repo in chronological order.
    add_index :project_index_runs, %i[project_repository_id created_at]
  end
end
