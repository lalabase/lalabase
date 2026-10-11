# frozen_string_literal: true

class CreateChangelogReadings < ActiveRecord::Migration[8.0]
  def change
    create_table :changelog_readings, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.datetime :last_read_at, null: false
      t.timestamps
    end
  end
end
