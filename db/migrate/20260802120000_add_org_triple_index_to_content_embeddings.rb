# frozen_string_literal: true

# Embedding v2 PR 6b (review C4) — the retention sweep's working index.
#
# Sweep 3 counts and batch-deletes sidecar rows by (organisation_id, provider, model,
# dims) — EmbeddingSpace#content_embeddings, the same predicate the read seam filters
# on. The existing idx_content_embeddings_org_space interposes embeddable_type at
# position 2, which the retention predicate does not constrain, so those queries fall
# back to the bare organisation_id prefix and re-scan the org's whole sidecar per
# batch. Harmless at today's row counts; this index makes the sweep exact before the
# table grows into one where it is not.
#
# CONCURRENTLY (hence disable_ddl_transaction!): content_embeddings is the large,
# hot table of this subsystem — an exclusive lock for an index build is exactly the
# kind of pause the nightly jobs and the write-both paths must not hit.
class AddOrgTripleIndexToContentEmbeddings < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :content_embeddings,
              %i[organisation_id embedding_provider embedding_model embedding_dims],
              name: 'idx_content_embeddings_org_triple',
              algorithm: :concurrently
  end
end
