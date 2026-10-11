class CreateFragments < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    create_table :fragments, id: :uuid do |t|
      t.references :fragmentable, polymorphic: true, null: false, type: :uuid
      t.text :plain_text_content
      t.vector :embedding, limit: 1536 # For pgvector
      t.string :version_token
      t.references :organisation, null: false, foreign_key: true, type: :uuid

      t.timestamps
    end

    add_index :fragments, [:fragmentable_type, :fragmentable_id]
    add_index :fragments, :version_token

    # Create a vector index with a specific operator class and algorithm
    add_index :fragments, :embedding, using: :ivfflat, opclass: :vector_l2_ops, algorithm: :concurrently
  end
end
