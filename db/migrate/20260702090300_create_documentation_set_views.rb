# frozen_string_literal: true

class CreateDocumentationSetViews < ActiveRecord::Migration[8.0]
  def change
    create_table :documentation_set_views, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :documentation_set, type: :uuid, null: false, foreign_key: true
      # Disposable per-user marker; drop on user hard-delete.
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :last_viewed_at, null: false
      t.timestamps
    end

    add_index :documentation_set_views, %i[documentation_set_id user_id],
              unique: true, name: 'idx_doc_set_views_set_user'
  end
end
