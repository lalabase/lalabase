class AddEmbeddingFieldsToTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :tickets, :embeddings_creation_flag, :boolean
    add_column :tickets, :embedding_creation_error, :text
  end
end
