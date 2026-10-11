class RenameChangesInUserActivities < ActiveRecord::Migration[8.0]
  def change
    rename_column :user_activities, :changes, :attribute_changes
  end
end