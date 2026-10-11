# frozen_string_literal: true

# One embedding vector of one record in ONE vector space (provider, model, dims)
# — the sidecar row behind the embedding-v2 storage model
# (doc/embedding_v2_multidim_plan.md §3). Written as a shadow copy from PR 2 on;
# since PR 4b ALL retrieval reads go through Embeddings::NearestNeighbors, and the
# inline vector columns are only the write-both safety net until PR 7. Deliberately
# NO has_neighbors — the query object owns metric, cast and index predicates.
# == Schema Information
#
# Table name: content_embeddings
#
#  id                 :uuid             not null, primary key
#  embeddable_type    :string           not null
#  embedded_at        :datetime         not null
#  embedding          :vector           not null
#  embedding_dims     :integer          not null
#  embedding_model    :string           not null
#  embedding_provider :string           not null
#  indexed            :boolean          default(FALSE), not null
#  source_hash        :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  embeddable_id      :uuid             not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  idx_ce_code_symbol_1024_cos          (((embedding)::vector(1024)) vector_cosine_ops) WHERE (((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 1024) AND indexed) USING hnsw
#  idx_ce_code_symbol_1536_cos          (((embedding)::vector(1536)) vector_cosine_ops) WHERE (((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 1536) AND indexed) USING hnsw
#  idx_ce_code_symbol_3072_cos          (((embedding)::halfvec(3072)) halfvec_cosine_ops) WHERE (((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 3072) AND indexed) USING hnsw
#  idx_ce_code_symbol_768_cos           (((embedding)::vector(768)) vector_cosine_ops) WHERE (((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 768) AND indexed) USING hnsw
#  idx_ce_fragment_1024_l2              (((embedding)::vector(1024)) vector_l2_ops) WHERE (((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 1024) AND indexed) USING hnsw
#  idx_ce_fragment_1536_l2              (((embedding)::vector(1536)) vector_l2_ops) WHERE (((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 1536) AND indexed) USING hnsw
#  idx_ce_fragment_3072_l2              (((embedding)::halfvec(3072)) halfvec_l2_ops) WHERE (((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 3072) AND indexed) USING hnsw
#  idx_ce_fragment_768_l2               (((embedding)::vector(768)) vector_l2_ops) WHERE (((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 768) AND indexed) USING hnsw
#  idx_content_embeddings_org_space     (organisation_id,embeddable_type,embedding_provider,embedding_model,embedding_dims)
#  idx_content_embeddings_unique_space  (embeddable_type,embeddable_id,embedding_provider,embedding_model,embedding_dims) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id) ON DELETE => cascade
#
class ContentEmbedding < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :embeddable, polymorphic: true

  validates :embedding_provider, :embedding_model, :embedding_dims,
            :source_hash, :embedding, :embedded_at, presence: true

  # SHA-256 over the EXACT string that was handed to the embedding endpoint.
  # ONE definition so every write path (and later the PR-3 backfill and the
  # PR-6 delta reindex) hashes identically (feedback_encapsulate_no_copy).
  def self.source_hash_for(text)
    Digest::SHA256.hexdigest(text.to_s)
  end

  # Bulk-removes the sidecar rows of a set of embeddables — the explicit
  # companion for every callback-free delete path (delete_all / bulk purges).
  # `embeddable_ids` may be an Array or a Relation (subselect); callers on a
  # delete path MUST call this BEFORE deleting the embeddables (the subselect
  # needs the rows) and inside the same transaction.
  def self.purge_for(embeddable_type:, embeddable_ids:)
    where(embeddable_type: embeddable_type, embeddable_id: embeddable_ids).delete_all
  end
end
