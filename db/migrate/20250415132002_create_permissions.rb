class CreatePermissions < ActiveRecord::Migration[8.0]
  def change
    create_table :permissions, id: :uuid do |t|
      t.uuid :role_id, null: false
      t.string :category, null: false
      t.string :action, null: false
      t.boolean :allowed, default: false

      t.timestamps
    end

    add_index :permissions, [:role_id, :category, :action], unique: true
    add_foreign_key :permissions, :roles
  end
end