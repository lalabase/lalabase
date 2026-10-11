# frozen_string_literal: true

# Migration: Simplify the notification system to a simple on/off
#
# WHY:
# The digest/quiet-hours system was overdimensioned for the current need.
# Instead of 4 frequencies (immediate/daily/weekly/never) + quiet hours + digest system
# there is now only: on (immediate) or off (never).
#
# WHAT HAPPENS:
# 1. notification_preferences: remove quiet_hours + timezone columns
# 2. notifications: remove digest_sent_at + digest_frequency columns
# 3. drop the notification_locks table entirely
# 4. remove the check_channel_frequency_combinations constraint
# 5. normalize existing data (enabled→immediate, disabled→never)
class SimplifyNotificationPreferences < ActiveRecord::Migration[8.0]
  def up
    # 1. Normalize existing data BEFORE we change constraints
    execute <<~SQL
      UPDATE notification_preferences
      SET frequency = 'immediate'
      WHERE enabled = true AND frequency != 'immediate';
    SQL

    execute <<~SQL
      UPDATE notification_preferences
      SET frequency = 'never'
      WHERE enabled = false AND frequency != 'never';
    SQL

    # 2. Remove CHECK constraint (no longer needed, since only immediate/never remain)
    execute <<~SQL
      ALTER TABLE notification_preferences
      DROP CONSTRAINT IF EXISTS check_channel_frequency_combinations;
    SQL

    # 3. notification_preferences: remove quiet_hours + timezone
    remove_column :notification_preferences, :quiet_hours, :jsonb
    remove_column :notification_preferences, :timezone, :string

    # 4. notifications: remove digest columns
    remove_column :notifications, :digest_sent_at, :datetime
    remove_column :notifications, :digest_frequency, :string

    # 5. drop the notification_locks table entirely
    drop_table :notification_locks
  end

  def down
    # Restore the notification_locks table
    create_table :notification_locks do |t|
      t.string :lock_key, null: false
      t.datetime :acquired_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :lock_key, unique: true
      t.index :expires_at
    end

    # notifications: restore digest columns
    add_column :notifications, :digest_sent_at, :datetime
    add_column :notifications, :digest_frequency, :string

    # notification_preferences: restore quiet_hours + timezone
    add_column :notification_preferences, :timezone, :string, default: 'Europe/Berlin'
    add_column :notification_preferences, :quiet_hours, :jsonb, default: {}, null: false

    # Restore CHECK constraint
    execute <<~SQL
      ALTER TABLE notification_preferences
      ADD CONSTRAINT check_channel_frequency_combinations CHECK (
        (channel::text = 'in_app'::text AND (frequency::text = ANY (ARRAY['immediate'::text, 'never'::text])))
        OR (channel::text = 'email'::text AND (frequency::text = ANY (ARRAY['immediate'::text, 'daily'::text, 'weekly'::text, 'never'::text])))
        OR (channel::text = 'webhook'::text AND (frequency::text = ANY (ARRAY['immediate'::text, 'never'::text])))
      );
    SQL
  end
end
