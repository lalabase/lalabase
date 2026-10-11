# frozen_string_literal: true

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
FactoryBot.define do
  factory :content_embedding do
    # A CodeSymbol by default: it is the only embeddable whose factory is
    # self-sufficient (Fragment needs a fragmentable). Org derives from it so the
    # default row is internally consistent; specs override :embeddable (+ matching
    # :organisation) for Fragment / ProjectCapability / ProjectLayer4Vision.
    association :embeddable, factory: :code_symbol
    organisation { embeddable.organisation }
    embedding_provider { 'openai' }
    embedding_model { 'text-embedding-3-small' }
    embedding_dims { 1536 }
    # The CHECK (vector_dims(embedding) = embedding_dims) requires the vector
    # length to match embedding_dims — keep the two in sync in overrides.
    embedding { Array.new(1536, 0.001) }
    source_hash { ContentEmbedding.source_hash_for('sample') }
    indexed { true }
    embedded_at { Time.current }
  end
end
