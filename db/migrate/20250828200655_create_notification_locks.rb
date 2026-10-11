class CreateNotificationLocks < ActiveRecord::Migration[8.0]
  def change
    create_table :notification_locks do |t|
      t.string :lock_key, null: false
      t.datetime :acquired_at, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :notification_locks, :lock_key, unique: true
    add_index :notification_locks, :expires_at
  end
end
