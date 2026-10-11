class AddChangelogLastReadAtToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :changelog_last_read_at, :datetime

    execute <<~SQL
      UPDATE users
      SET changelog_last_read_at = cr.last_read_at
      FROM changelog_readings cr
      WHERE cr.user_id = users.id
    SQL

    drop_table :changelog_readings
  end

  def down
    create_table :changelog_readings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false
      t.datetime :last_read_at, null: false
      t.timestamps
      t.index :user_id, unique: true
    end
    add_foreign_key :changelog_readings, :users

    execute <<~SQL
      INSERT INTO changelog_readings (user_id, last_read_at, created_at, updated_at)
      SELECT id, changelog_last_read_at, NOW(), NOW()
      FROM users
      WHERE changelog_last_read_at IS NOT NULL
    SQL

    remove_column :users, :changelog_last_read_at
  end
end
