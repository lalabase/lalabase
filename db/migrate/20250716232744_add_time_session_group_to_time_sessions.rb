class AddTimeSessionGroupToTimeSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :time_sessions, :time_session_group_id, :uuid
    add_foreign_key :time_sessions, :time_session_groups
    add_index :time_sessions, :time_session_group_id
  end
end
