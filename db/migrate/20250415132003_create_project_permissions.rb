class CreateProjectPermissions < ActiveRecord::Migration[8.0]
  def change
    create_table :project_permissions, id: :uuid do |t|
      t.uuid :project_id, null: false
      t.uuid :user_id, null: false

      t.integer :tickets_access, default: 0, null: false
      t.integer :notes_access, default: 0, null: false
      t.integer :chats_access, default: 0, null: false
      t.integer :time_sessions_access, default: 0, null: false
      t.integer :documents_access, default: 0, null: false

      t.timestamps
    end

    add_index :project_permissions, [:user_id, :project_id], unique: true
    add_foreign_key :project_permissions, :users
    add_foreign_key :project_permissions, :projects
  end
end