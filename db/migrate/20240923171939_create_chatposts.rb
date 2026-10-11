class CreateChatposts < ActiveRecord::Migration[7.2]
  def change
    create_table :chatposts, id: :uuid do |t|
      t.text :content
      t.string :role
      t.uuid :user_id, null: true
      t.uuid :chat_id, null: false
      t.uuid :organisation_id, null: false
      t.timestamps
    end
  end
end
