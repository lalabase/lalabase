# frozen_string_literal: true

class AddTimezoneToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :timezone, :string, default: 'Europe/Berlin'
    
    # Add index for timezone-based queries
    add_index :users, :timezone
  end
end