class CreateTimeSessionGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :time_session_groups, id: :uuid do |t|
      t.string :name, null: false
      t.boolean :billed, default: false, null: false
      t.string :invoice_number
      t.uuid :organisation_id, null: false
      t.uuid :project_id, null: false
      t.datetime :billed_at

      t.timestamps
    end

    add_foreign_key :time_session_groups, :organisations
    add_foreign_key :time_session_groups, :projects
    
    add_index :time_session_groups, :organisation_id
    add_index :time_session_groups, :project_id
    add_index :time_session_groups, [:organisation_id, :billed]
    add_index :time_session_groups, [:project_id, :billed]
  end
end
