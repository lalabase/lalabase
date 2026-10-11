# frozen_string_literal: true

class CreatePersonalAccessTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :personal_access_tokens, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_hash, null: false
      t.string :token_prefix, null: false, limit: 12
      t.datetime :last_used_at
      t.datetime :expires_at, null: false
      t.datetime :revoked_at

      t.timestamps

      t.index :token_hash, unique: true
      t.index %i[user_id created_at]
    end
  end
end
