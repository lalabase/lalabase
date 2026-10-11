# frozen_string_literal: true

class AddSessionTimeoutMinutesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :session_timeout_minutes, :integer, default: 30, null: false
  end
end
