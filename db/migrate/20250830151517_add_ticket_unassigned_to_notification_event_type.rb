class AddTicketUnassignedToNotificationEventType < ActiveRecord::Migration[8.0]
  def up
    # Add the new enum value to the PostgreSQL enum type
    execute <<-SQL
      ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'ticket_unassigned' AFTER 'ticket_assigned';
    SQL
  end

  def down
    # Note: PostgreSQL doesn't support removing enum values easily
    # You would need to recreate the entire enum type and all dependent columns
    raise ActiveRecord::IrreversibleMigration, "Cannot remove enum values from PostgreSQL enums"
  end
end
