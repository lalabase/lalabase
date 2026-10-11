class AddEmbeddingFieldsToPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :posts, :create_embeddings, :boolean, default: true
    add_column :posts, :embeddings_creation_flag, :boolean
    add_column :posts, :embedding_creation_error, :text

    add_column :posts, :plain_text_version, :text
    add_column :posts, :plain_text_word_count, :integer

  end
end
