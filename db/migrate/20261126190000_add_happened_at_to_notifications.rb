# frozen_string_literal: true

# notifications.happened_at: the latest event's own time, beside last_event_at,
# which says when that event reached the row (Notifications::RowEvents.arrival).
# The lists order and cut `since` by the arrival; a row's time label, the
# representative of a bundle and the times of a group's activities read this one.
#
# Null, no default and no backfill, on purpose: a row written before this column
# carries the event's own time in last_event_at, and Notification#happened_at
# answers that when the column is empty. So does a row an old process writes
# during the deploy, which a NOT NULL column would refuse.
class AddHappenedAtToNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :notifications, :happened_at, :datetime
  end
end
