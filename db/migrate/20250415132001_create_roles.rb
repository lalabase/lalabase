class CreateRoles < ActiveRecord::Migration[8.0]
  def change
    create_table :roles, id: :uuid do |t|
      t.string :title, null: false
      t.text :description
      t.boolean :default_role, default: false
      t.uuid :organisation_id, null: false

      t.timestamps
    end

    add_index :roles, [:organisation_id, :title], unique: true
    add_foreign_key :roles, :organisations
  end
end