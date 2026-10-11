class CreateImportedObjects < ActiveRecord::Migration[8.0]
  def change
    create_table :imported_objects, id: :uuid do |t|
      t.references :organisation, null: false, foreign_key: true, type: :uuid
      t.references :importable, polymorphic: true, null: false, type: :uuid
      t.string :import_session_id, null: false
      t.string :import_source, null: false
      t.datetime :imported_at, null: false
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :imported_objects, [:organisation_id, :import_session_id]
    add_index :imported_objects, [:import_session_id, :import_source]
    add_index :imported_objects, [:importable_type, :importable_id]
    add_index :imported_objects, :imported_at
  end
end
