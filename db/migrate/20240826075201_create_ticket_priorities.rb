# frozen_string_literal: true

class CreateTicketPriorities < ActiveRecord::Migration[7.2]
  def change
    create_table :ticket_priorities, id: :uuid do |t|
      t.string :color
      t.string :name
      t.boolean :is_default
      t.integer :position
      t.uuid :organisation_id, null: false
      t.timestamps
    end
  end
end
