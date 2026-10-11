# frozen_string_literal: true

class CreateTickets < ActiveRecord::Migration[7.2]
  def change
    create_table :tickets, id: :uuid do |t|
      t.string :title, null: false
      t.text :content
      t.uuid :project_id, null: false
      t.text :summary
      t.uuid :ticket_status_id, null: true
      t.uuid :ticket_priority_id, null: true
      t.uuid :organisation_id, null: false
      t.uuid :creator_id, null: false 
      t.uuid :updater_id, null: true
      t.timestamps
    end
  end
end
