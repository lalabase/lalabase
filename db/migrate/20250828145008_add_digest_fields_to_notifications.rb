class AddDigestFieldsToNotifications < ActiveRecord::Migration[8.0]
  def change
    add_column :notifications, :digest_sent_at, :datetime
    add_column :notifications, :digest_frequency, :string
  end
end
