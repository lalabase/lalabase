# frozen_string_literal: true

class CreatePosts < ActiveRecord::Migration[7.2]
  def change
    create_table :posts, id: :uuid do |t|
      t.uuid :ticket_id, null: false
      t.uuid :user_id, null: true
      t.uuid :organisation_id, null: false
      t.timestamps
    end
  end
end
