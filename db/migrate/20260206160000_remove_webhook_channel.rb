# frozen_string_literal: true

class RemoveWebhookChannel < ActiveRecord::Migration[8.0]
  def up
    # 1. Delete all webhook data (never delivered anyway - WebhookDeliveryJob never existed)
    execute "DELETE FROM notification_preferences WHERE channel = 'webhook'"
    execute "DELETE FROM notifications WHERE channel = 'webhook'"

    # 2. Replace PostgreSQL enum: remove 'webhook' value
    #    PostgreSQL doesn't support ALTER TYPE ... DROP VALUE, so we recreate the enum.
    #    Must drop column defaults first since they reference the old enum type.
    execute <<~SQL
      -- Create new enum without webhook
      CREATE TYPE notification_channel_v2 AS ENUM ('in_app', 'email');

      -- Drop column defaults that reference old enum type
      ALTER TABLE notifications ALTER COLUMN channel DROP DEFAULT;
      ALTER TABLE notification_preferences ALTER COLUMN channel DROP DEFAULT;

      -- Switch notifications column to new enum
      ALTER TABLE notifications
        ALTER COLUMN channel TYPE notification_channel_v2
        USING channel::text::notification_channel_v2;

      -- Switch notification_preferences column to new enum
      ALTER TABLE notification_preferences
        ALTER COLUMN channel TYPE notification_channel_v2
        USING channel::text::notification_channel_v2;

      -- Drop old enum and rename new one
      DROP TYPE notification_channel;
      ALTER TYPE notification_channel_v2 RENAME TO notification_channel;

      -- Restore column defaults
      ALTER TABLE notifications ALTER COLUMN channel SET DEFAULT 'in_app'::notification_channel;
      ALTER TABLE notification_preferences ALTER COLUMN channel SET DEFAULT 'in_app'::notification_channel;
    SQL
  end

  def down
    execute <<~SQL
      -- Recreate enum with webhook
      CREATE TYPE notification_channel_v2 AS ENUM ('in_app', 'email', 'webhook');

      -- Drop column defaults
      ALTER TABLE notifications ALTER COLUMN channel DROP DEFAULT;
      ALTER TABLE notification_preferences ALTER COLUMN channel DROP DEFAULT;

      ALTER TABLE notifications
        ALTER COLUMN channel TYPE notification_channel_v2
        USING channel::text::notification_channel_v2;

      ALTER TABLE notification_preferences
        ALTER COLUMN channel TYPE notification_channel_v2
        USING channel::text::notification_channel_v2;

      DROP TYPE notification_channel;
      ALTER TYPE notification_channel_v2 RENAME TO notification_channel;

      -- Restore column defaults
      ALTER TABLE notifications ALTER COLUMN channel SET DEFAULT 'in_app'::notification_channel;
      ALTER TABLE notification_preferences ALTER COLUMN channel SET DEFAULT 'in_app'::notification_channel;
    SQL
  end
end
