# frozen_string_literal: true

# The token inbox without `arrived_since` (REST and MCP, what every client of
# API 1.15 asks) cuts `since` on, and orders by, when a row's latest event
# happened: Notification::HAPPENED_AT_SQL, COALESCE(happened_at, last_event_at),
# because a row written before happened_at answers last_event_at. The index on
# recipient and last_event_at serves the arrival (`arrived_since`, the web
# lists), not this expression, so each such call filtered and sorted every row
# of the recipient. The expression has to stay the one of HAPPENED_AT_SQL, or
# the planner does not use the index (spec/services/notifications/inbox_query_index_spec.rb).
# Concurrent, so the running app is not blocked while the index builds.
class AddRecipientHappenedAtIndexToNotifications < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :notifications, 'recipient_id, COALESCE(happened_at, last_event_at)',
              name: 'index_notifications_on_recipient_and_happened_at',
              algorithm: :concurrently
  end
end
