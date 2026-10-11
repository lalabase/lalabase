class CreateTags < ActiveRecord::Migration[8.0]
  def change
    create_table :tags, id: :uuid do |t|
      t.string :name, null: false
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, foreign_key: true
      
      t.timestamps
      
      t.index [:name, :organisation_id], unique: true
    end
  end
end