# frozen_string_literal: true

# Presence heartbeat column. Nullable, no default -> no table rewrite / long
# lock on the (small) users table. Written via a throttled update_all from the
# request cycle (User::Presence#mark_seen!), read for the "online" dot and the
# admin "last active" tile. The index backs future sort/filter by activity.
class AddLastSeenAtToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :last_seen_at, :datetime
    add_index :users, :last_seen_at
  end
end
