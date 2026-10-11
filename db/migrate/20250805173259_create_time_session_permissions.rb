class CreateTimeSessionPermissions < ActiveRecord::Migration[8.0]
  def change
    create_table :time_session_permissions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :project, null: false, foreign_key: true, type: :uuid
      
      # Granulare Rechte
      t.boolean :can_create_own, default: true, null: false
      t.boolean :can_view_own, default: true, null: false
      t.boolean :can_edit_own, default: true, null: false
      t.boolean :can_delete_own, default: true, null: false
      t.boolean :can_view_all, default: false, null: false
      t.boolean :can_edit_all, default: false, null: false
      t.boolean :can_delete_all, default: false, null: false
      
      t.timestamps
    end
    
    add_index :time_session_permissions, [:user_id, :project_id], unique: true, name: 'index_time_session_permissions_unique'
    add_index :time_session_permissions, :project_id, name: 'index_time_session_permissions_on_project'
  end
end
