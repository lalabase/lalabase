# frozen_string_literal: true

# The run of a bulk change is one event (doc/ticket_bulk_edit_plan.md, D4): the
# followers of the changed tickets get one notification per run instead of one
# per ticket. Adds the value to the existing PG enum; mirrors
# 20260528150000_add_index_events_to_notification_event_type.
class AddTicketsBulkChangedToNotificationEventType < ActiveRecord::Migration[8.0]
  def up
    execute <<-SQL
      ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'tickets_bulk_changed' AFTER 'index_failed';
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Cannot remove enum values from PostgreSQL enums'
  end
end
