# frozen_string_literal: true

class AddProjectContextFieldsToChats < ActiveRecord::Migration[8.0]
  def change
    change_table :chats, bulk: true do |t|
      t.string :title
      t.string :language
      t.boolean :language_locked, null: false, default: true
      t.references :project_repository, type: :uuid, foreign_key: true
      t.datetime :last_message_at
    end

    add_index :chats, :last_message_at
  end
end
