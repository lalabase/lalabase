class CreateSystemSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :system_settings, id: :uuid do |t|
      t.string :key, null: false
      t.text :value
      t.string :data_type, default: 'string'
      t.text :description

      t.timestamps
    end
    add_index :system_settings, :key, unique: true
  end
end
