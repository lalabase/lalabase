# frozen_string_literal: true

# The shared people directory of an organisation: one row per person the
# consultant and the customer keep track of together. A row may link to a member
# (user_id); every row keeps its own name, so an unlink loses nothing.
class CreatePeople < ActiveRecord::Migration[8.1]
  def change
    create_table :people, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, null: true, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.string :function
      t.string :department
      t.string :company
      t.string :email
      t.string :phone
      t.text :notes
      t.references :creator, type: :uuid, null: true, index: false, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updater, type: :uuid, null: true, index: false, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :people, %i[organisation_id normalized_name]
    add_index :people, %i[organisation_id user_id], unique: true, where: 'user_id IS NOT NULL',
                                                     name: 'index_people_on_organisation_id_and_user_id'
  end
end
