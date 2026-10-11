# frozen_string_literal: true

# The token inbox (Notifications::InboxQuery) lists a recipient's rows by their
# latest activity, the column its `since` cursor cuts on; the existing indexes
# serve recipient + state + created_at, the previous ordering. Concurrent, so
# the running app is not blocked while the index builds.
class AddRecipientLastEventIndexToNotifications < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :notifications, %i[recipient_id last_event_at],
              name: 'index_notifications_on_recipient_and_last_event_at',
              algorithm: :concurrently
  end
end
