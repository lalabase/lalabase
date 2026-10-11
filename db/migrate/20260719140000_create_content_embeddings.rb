# frozen_string_literal: true

# Embedding v2 PR 2 (doc/embedding_v2_pr2_sidecar_plan.md): polymorphic sidecar
# table for per-vector-space embeddings. Written as a shadow copy from PR 2 on
# (write-both); reads stay on the inline columns until PR 4b. ANN indexes come
# in PR 4a — deliberately none here.
class CreateContentEmbeddings < ActiveRecord::Migration[8.0]
  def change
    create_table :content_embeddings, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid    :organisation_id, null: false        # tenant scope + FK
      t.string  :embeddable_type, null: false        # 'CodeSymbol' | 'Fragment' | 'ProjectCapability' | 'ProjectLayer4Vision'
      t.uuid    :embeddable_id,   null: false
      t.string  :embedding_provider, null: false     # routing key ('openai', 'google', …)
      t.string  :embedding_model,    null: false
      t.integer :embedding_dims,     null: false
      t.vector  :embedding,          null: false     # UNTYPED — per-row dimensionality (main plan §3.4)
      t.string  :source_hash,        null: false     # SHA-256 of the exact embedded text (§5.2)
      t.boolean :indexed, null: false, default: false # ANN index membership (used from PR 4a on)
      t.datetime :embedded_at, null: false
      t.timestamps
    end

    # one embedding per record per vector space; the leftmost prefix also serves
    # (embeddable_type, embeddable_id) lookups — no separate polymorphic index
    # (reference_migration_rules: leftmost-prefix / polymorphic-index-duplicate)
    add_index :content_embeddings,
              %i[embeddable_type embeddable_id embedding_provider embedding_model embedding_dims],
              unique: true, name: 'idx_content_embeddings_unique_space'
    # org-scoped space accounting (reindex skip logic, GC, retention counting);
    # its leftmost prefix also covers plain organisation_id lookups (tenant scope)
    add_index :content_embeddings,
              %i[organisation_id embeddable_type embedding_provider embedding_model embedding_dims],
              name: 'idx_content_embeddings_org_space'
    # DB-level ON DELETE CASCADE — a DELIBERATE deviation from the house NO-ACTION
    # convention. content_embeddings hold DERIVED data (shadow copies of vectors),
    # never a source of truth, so a hard org delete should take them with it. Unlike
    # an app-layer `dependent:`, a DB cascade is NOT bypassed when the org is removed
    # via a parent's delete_all — it closes the open org-CLEAR path (no orphaned
    # sidecar rows survive a tenant hard-delete).
    add_foreign_key :content_embeddings, :organisations, on_delete: :cascade

    # integrity anchor: a row can never lie about its dimensionality
    # (vector_dims() is immutable → CHECK-safe; table is empty → valid instantly)
    add_check_constraint :content_embeddings,
                         'vector_dims(embedding) = embedding_dims',
                         name: 'content_embeddings_dims_check'
  end
end
