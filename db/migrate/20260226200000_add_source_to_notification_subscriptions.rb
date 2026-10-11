# frozen_string_literal: true

class AddSourceToNotificationSubscriptions < ActiveRecord::Migration[8.0]
  def change
    add_column :notification_subscriptions, :source, :string, null: true
    add_reference :notification_subscriptions, :subscribed_by,
                  type: :uuid, null: true, foreign_key: { to_table: :users }
  end
end
