# frozen_string_literal: true

class CreateProjectCapabilities < ActiveRecord::Migration[8.0]
  def change
    create_table :project_capabilities, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description, null: false
      t.jsonb :key_modules, null: false, default: []
      t.column :description_embedding, 'vector(1536)'
      t.string :embedding_provider, null: false, default: 'openai'
      t.string :embedding_model, null: false, default: 'text-embedding-ada-002'
      t.boolean :auto_generated, null: false, default: true
      t.references :edited_by_user, type: :uuid, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :project_capabilities, %i[project_id name], unique: true
  end
end
