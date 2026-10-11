class AddProjectIdToNotifications < ActiveRecord::Migration[8.0]
  def change
    add_reference :notifications, :project, null: true, foreign_key: true, type: :uuid
    add_index :notifications, [:project_id, :created_at], name: 'index_notifications_on_project_and_created_at'
    add_index :notifications, [:recipient_id, :project_id, :state], name: 'index_notifications_on_recipient_project_state'
  end
end
