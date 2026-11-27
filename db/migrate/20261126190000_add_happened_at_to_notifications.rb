# frozen_string_literal: true

# notifications.happened_at: the latest event's own time, beside last_event_at,
# which says when that event reached the row (Notifications::RowEvents.arrival).
# The lists order by the arrival, and so does the token inbox's arrived_since;
# a row's time label, the representative of a bundle, the times of a group's
# activities and the token inbox's last_event_at and `since` read this one.
#
# Null, no default and no backfill, on purpose: a row written before this column
# carries the event's own time in last_event_at, and Notification#happened_at
# answers that when the column is empty. So does a row an old process writes
# during the deploy, which a NOT NULL column would refuse.
#
# ⚠️ Restart the job workers right after this migration. Between it and the
# restart, a process of the old code holds prepared SELECTs of
# notifications.*, which PostgreSQL refuses once the table has a new column
# ("cached plan must not change result type"). Outside a transaction Rails
# prepares them again. Inside one it raises PreparedStatementCacheExpired, and
# clears the statement only when that error leaves the transaction:
# OutboxEvent#process! turns it into a rollback, so an old worker fails every
# fanout on that connection and reschedules it until it restarts. An old web
# process answers a request inside a transaction with a 500 now and then until
# its own restart. Every column added to this table opens the same window.
#
# ⚠️ A second window lasts while workers of both releases run side by side, as
# in a rolling restart. An old worker that folds an event into a row a new
# worker wrote raises the count and moves last_event_at as it always did, but
# never happened_at, a column it does not know. That row keeps the earlier
# event's time for its label, for the choice of its bundle's representative
# and for the `since` of the token inbox, until a fold by the new code moves it
# (RowEvents.fold! takes the later time). So stop every old worker before the
# first new one starts. `docker compose up -d` does (one worker container, replaced
# after the web container migrated); a deploy of several workers restarts them
# all at once, not one by one. The upgrade notes in CHANGELOG.md say the same.
class AddHappenedAtToNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :notifications, :happened_at, :datetime
  end
end
