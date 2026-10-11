# frozen_string_literal: true

class SimplifyTicketNotifications < ActiveRecord::Migration[8.0]
  def up
    # 1. Convert all 'immediate' subscriptions to 'follow'
    # The simplified system only uses follow/mute, not immediate
    execute "UPDATE notification_subscriptions SET mode = 'follow' WHERE mode = 'immediate'"

    # 2. Set default ticket_notifications for existing users
    # All toggles default to true so existing users keep getting all notifications
    execute <<-SQL
      UPDATE users
      SET preferences = jsonb_set(
        COALESCE(preferences, '{}'),
        '{ticket_notifications}',
        '{"on_status_change": true, "on_priority_change": true, "on_comment": true, "auto_follow_created": true}'
      )
      WHERE NOT (COALESCE(preferences, '{}') ? 'ticket_notifications')
    SQL
  end

  def down
    # Remove ticket_notifications from user preferences
    execute <<-SQL
      UPDATE users
      SET preferences = preferences - 'ticket_notifications'
      WHERE preferences ? 'ticket_notifications'
    SQL
    # Note: We cannot restore 'immediate' subscriptions as we don't know which ones were converted
  end
end
