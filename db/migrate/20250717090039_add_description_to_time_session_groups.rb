class AddDescriptionToTimeSessionGroups < ActiveRecord::Migration[8.0]
  def change
    add_column :time_session_groups, :description, :text
  end
end
