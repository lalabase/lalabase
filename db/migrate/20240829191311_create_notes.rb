# frozen_string_literal: true

class CreateNotes < ActiveRecord::Migration[7.2]
  def change
    create_table :notes, id: :uuid do |t|
      t.string :title
      t.text :description
      t.text :content
      t.uuid :project_id, null: false
      t.uuid :organisation_id, null: false

      t.timestamps
    end
  end
end

