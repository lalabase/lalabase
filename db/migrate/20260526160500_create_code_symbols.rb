# frozen_string_literal: true

class CreateCodeSymbols < ActiveRecord::Migration[8.0]
  def change
    create_table :code_symbols, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :project_repository, type: :uuid, null: false, foreign_key: true
      t.string :symbol_type, null: false
      t.string :name, null: false
      t.string :qualified_name, null: false
      t.string :file_path, null: false
      t.integer :start_line, null: false
      t.integer :end_line, null: false
      t.text :signature
      t.column :signature_embedding, 'vector(1536)'
      t.string :embedding_provider, null: false, default: 'openai'
      t.string :embedding_model, null: false, default: 'text-embedding-ada-002'
      t.string :language, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :code_symbols, %i[project_repository_id qualified_name], name: 'idx_code_symbols_repo_qname'
    add_index :code_symbols, %i[project_repository_id file_path],      name: 'idx_code_symbols_repo_path'
  end
end
