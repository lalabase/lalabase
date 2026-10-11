# frozen_string_literal: true

class CreateProjects < ActiveRecord::Migration[7.2]
  def change
    create_table :projects, id: :uuid do |t|
      t.string :name
      t.text :description
      t.text :repository
      t.uuid :organisation_id, null: false

      t.timestamps
    end
  end
end
