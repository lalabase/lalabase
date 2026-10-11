class AddEmbeddingFieldsToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :create_embeddings, :boolean, default: false
    add_column :notes, :embeddings_creation_flag, :boolean
    add_column :notes, :embedding_creation_error, :text
  end
end
