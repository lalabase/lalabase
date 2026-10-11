class CreateViewStates < ActiveRecord::Migration[8.0]
  def change
    create_table :view_states, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :key, null: false
      t.jsonb :state, default: {}
      t.references :viewable, polymorphic: true, null: false, type: :uuid
      t.references :organisation, null: false, foreign_key: true, type: :uuid

      t.timestamps
    end
    add_index :view_states, :key
    add_index :view_states, [:user_id, :key, :viewable_type, :viewable_id, :organisation_id], 
              unique: true, 
              name: 'index_view_states_unique'
  end
end
