class CreatePostDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :post_documents, id: :uuid do |t|
      t.uuid :post_id, null: false
      t.uuid :organisation_id, null: false
      t.text :plain_text_version
      t.integer :plain_text_word_count
      t.boolean :create_embeddings, default: true
      t.boolean :embeddings_creation_flag
      t.text :embedding_creation_error

      t.timestamps
    end
  end
end
