class CreateChats < ActiveRecord::Migration[7.2]
  def change
    create_table :chats, id: :uuid do |t|
      t.uuid :project_id, null: false
      t.uuid :organisation_id, null: false
      t.timestamps
    end
  end
end
