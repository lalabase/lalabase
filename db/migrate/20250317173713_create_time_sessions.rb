class CreateTimeSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :time_sessions, id: :uuid do |t|
      t.datetime :occurred_on, null: false
      t.integer :duration, null: false
      t.text :description
      t.datetime :billed_at
      t.string :invoice_number
      t.datetime :deleted_at
      
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.references :ticket, null: true, foreign_key: true, type: :uuid
      t.references :creator, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      
      t.timestamps
    end

    add_index :time_sessions, :deleted_at
    add_index :time_sessions, [:creator_id, :occurred_on]
  end
end