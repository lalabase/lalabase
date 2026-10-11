# frozen_string_literal: true

# Self-service GDPR data export (Art. 15/20): one row per requested export,
# the generated ZIP is an ActiveStorage attachment on the row.
# See doc/user_data_export_plan.md.
class CreateUserDataExports < ActiveRecord::Migration[8.0]
  def change
    create_table :user_data_exports, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      # CASCADE covers a future hard DELETE only; the real erasure path is
      # soft-delete + anonymize, which purges these rows explicitly in
      # User::DeletionLifecycle#soft_delete_and_anonymize!.
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: 'pending'
      t.string :error_message
      t.datetime :completed_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :user_data_exports, %i[user_id created_at]

    # At most ONE active export per user, enforced at the DB layer. The model's
    # request-interval validation has a race window (double submit passes both
    # validations before either row is written); this index closes it — the
    # controller rescues RecordNotUnique.
    # NOTE: relies on status being stored as a STRING enum. A later switch to an
    # integer-backed enum must migrate this index alongside.
    add_index :user_data_exports, :user_id,
              where: "status IN ('pending','processing')",
              unique: true,
              name: 'idx_user_data_exports_one_active_per_user'
  end
end
