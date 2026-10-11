class AddIndexEventsToNotificationEventType < ActiveRecord::Migration[8.0]
  # Project-aware-chat M9-5: notify the repo connector when its code index
  # finishes (or fails). Adds two values to the existing PG enum. Mirrors
  # 20250830151517_add_ticket_unassigned_to_notification_event_type.
  def up
    execute <<-SQL
      ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'index_completed' AFTER 'system_message';
    SQL
    execute <<-SQL
      ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'index_failed' AFTER 'index_completed';
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Cannot remove enum values from PostgreSQL enums'
  end
end
