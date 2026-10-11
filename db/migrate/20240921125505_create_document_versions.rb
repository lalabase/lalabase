class CreateDocumentVersions < ActiveRecord::Migration[7.2]
  def change
    create_table :document_versions, id: :uuid do |t|
      t.uuid :document_id, null: false
      t.uuid :organisation_id, null: false
      t.text :plain_text_version
      t.integer :plain_text_word_count
      t.boolean :create_embeddings, default: true
      t.boolean :embeddings_creation_flag
      t.text :embedding_creation_error
      t.boolean :create_summary, default: false
      t.text :generated_summary, default: ""
      t.boolean :summary_creation_flag, default: false
      t.text :summary_creation_error, default: ""
      t.string :title
      t.text :description
      t.timestamps
    end
    add_reference :documents, :current_version, type: :uuid, foreign_key: { to_table: :document_versions }
  end
end
