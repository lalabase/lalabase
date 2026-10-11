# frozen_string_literal: true

class FixActivitiesChangesColumn < ActiveRecord::Migration[8.0]
  def up
    # Check if 'changes' column exists and rename it
    if column_exists?(:activities, :changes)
      rename_column :activities, :changes, :attribute_changes
    end
    
    # Ensure attribute_changes column exists with correct type
    unless column_exists?(:activities, :attribute_changes)
      add_column :activities, :attribute_changes, :jsonb, default: {}
    end
  end
  
  def down
    # Only rename back if we originally had a 'changes' column
    if column_exists?(:activities, :attribute_changes) && !column_exists?(:activities, :changes)
      rename_column :activities, :attribute_changes, :changes
    end
  end
end