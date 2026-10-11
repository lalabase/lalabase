# frozen_string_literal: true

# Per-user, per-org personal to-do list ("Notizblock"). Deliberately a dumb list:
# one-line title + optional priority, open/done via completed_at. STRICTLY private
# to the owner (acts_as_tenant on organisation AND scoped to user_id) — even an
# org admin must not see another user's tasks. No activity tracking, no soft delete.
class CreatePersonalTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :personal_tasks, id: :uuid do |t|
      # organisation_id is the leftmost column of the composite index below
      # (leftmost-prefix covers every tenant lookup we make), so no standalone
      # index here.
      #
      # FK mechanism mirrors the house convention (see ChatStylePreference):
      #  - organisation_id: NO ACTION — org deletion is Rails-driven via
      #    Organisation has_many :dependent => :destroy inside the org's tenant.
      #  - user_id: ON DELETE CASCADE — a user delete is cross-tenant; a DB-level
      #    cascade is tenant-independent, so a hard (GDPR) purge always cleans up.
      #    Never fires on the soft-delete path (SoftDeletable sets deleted_at).
      t.references :organisation, type: :uuid, null: false, index: false,
                                  foreign_key: true
      t.references :user, type: :uuid, null: false,
                          foreign_key: { on_delete: :cascade }

      t.string :title, null: false
      # Integer-backed enum: nil = no priority (the default). low=0/medium=1/high=2.
      t.integer :priority
      # Manual sort order (drag, later). 0 everywhere in MVP, so the model's
      # `ordered` scope falls back to created_at → effectively newest-first.
      t.integer :position, null: false, default: 0
      t.datetime :completed_at

      t.timestamps
    end

    # Covers the hot query: tasks for (org, user) split by open/done. completed_at
    # trails so the one index serves both `open` (IS NULL) and `done`.
    add_index :personal_tasks, %i[organisation_id user_id completed_at],
              name: 'index_personal_tasks_on_org_user_completed'
  end
end
