# frozen_string_literal: true

# Slice 7 of doc/ticket_bulk_edit_plan.md: a run now has a kind (change, move,
# delete), and a bulk move and a bulk delete are events of their own, so the
# notification says what happened instead of "geändert". Enum values as in
# 20260908170100_add_tickets_bulk_changed_to_notification_event_type.
class AddKindToTicketBulkRunsAndBulkMoveDeleteEvents < ActiveRecord::Migration[8.0]
  def up
    add_column :ticket_bulk_runs, :kind, :string, null: false, default: 'change'
    execute <<-SQL
      ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'tickets_bulk_moved' AFTER 'tickets_bulk_changed';
    SQL
    execute <<-SQL
      ALTER TYPE notification_event_type ADD VALUE IF NOT EXISTS 'tickets_bulk_deleted' AFTER 'tickets_bulk_moved';
    SQL
  end

  def down
    # The enum values stay: PostgreSQL cannot remove them (as in the migration above).
    remove_column :ticket_bulk_runs, :kind
  end
end
