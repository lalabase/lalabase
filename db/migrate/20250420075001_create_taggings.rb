class CreateTaggings < ActiveRecord::Migration[8.0]
  def change
    create_table :taggings, id: :uuid do |t|
      t.references :tag, type: :uuid, null: false, foreign_key: true
      t.references :taggable, type: :uuid, polymorphic: true, null: false
      t.references :user, type: :uuid, foreign_key: true
      
      t.timestamps
      
      t.index [:tag_id, :taggable_type, :taggable_id], unique: true, name: 'index_taggings_uniqueness'
    end
  end
end