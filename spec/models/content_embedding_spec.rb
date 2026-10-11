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
require 'rails_helper'

# Sidecar embedding row (embedding v2 PR 2). Guards the storage contract that
# every write path depends on: tenant isolation, the dimension CHECK, the
# per-vector-space unique index, and that a plain Ruby array round-trips through
# BOTH create! and the bulk insert_all/upsert_all paths into the untyped vector
# column (the model has NO has_neighbors, so this is the load-bearing proof that
# the write paths serialize correctly — main-plan §6 risk).
RSpec.describe ContentEmbedding do
  let(:organisation) { create(:organisation) }
  let(:other_org)    { create(:organisation) }
  let(:user)         { create(:user) }
  let(:project)      { create(:project, organisation: organisation) }
  # Fragments need a fragmentable; a Note is the lightest in-org one.
  let(:note)         { create(:note, organisation: organisation, project: project, creator: user) }

  # Tenant set BEFORE any tenanted model is built (reference_test_patterns). A
  # `before` (not `around`) — the suite's global before-hook resets the tenant, and
  # around-hooks wrap before-hooks, so an around would be cleared out from under us.
  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # A fresh in-org Fragment to hang a sidecar row on.
  def in_org_fragment
    create(:fragment, fragmentable: note, organisation: organisation)
  end

  describe 'acts_as_tenant isolation' do
    it 'scopes rows to the current tenant and hides cross-tenant rows' do
      mine = create(:content_embedding, organisation: organisation, embeddable: in_org_fragment)
      theirs = ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        other_note = create(:note, organisation: other_org, project: other_project, creator: create(:user))
        create(:content_embedding, organisation: other_org,
                                   embeddable: create(:fragment, fragmentable: other_note, organisation: other_org))
      end

      expect(described_class.all).to include(mine)
      expect(described_class.all).not_to include(theirs)
      expect(ActsAsTenant.with_tenant(other_org) { described_class.pluck(:id) }).to eq([theirs.id])
    end
  end

  describe 'the dimensionality CHECK (content_embeddings_dims_check)' do
    it 'rejects a row whose vector length disagrees with embedding_dims (no silent write)' do
      expect do
        create(:content_embedding, organisation: organisation, embeddable: in_org_fragment,
                                   embedding_dims: 1536, embedding: [0.1, 0.2, 0.3])
      end.to raise_error(ActiveRecord::StatementInvalid, /content_embeddings_dims_check|check constraint/i)
    end

    it 'accepts a row whose vector length matches embedding_dims' do
      expect do
        create(:content_embedding, organisation: organisation, embeddable: in_org_fragment,
                                   embedding_dims: 3, embedding: [0.1, 0.2, 0.3])
      end.not_to raise_error
    end
  end

  describe 'the per-vector-space unique index (idx_content_embeddings_unique_space)' do
    it 'forbids a second row for the same embeddable in the same (provider, model, dims) space' do
      fragment = in_org_fragment
      create(:content_embedding, organisation: organisation, embeddable: fragment)

      expect do
        create(:content_embedding, organisation: organisation, embeddable: fragment)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows the same embeddable in a DIFFERENT space (e.g. other model)' do
      fragment = in_org_fragment
      create(:content_embedding, organisation: organisation, embeddable: fragment)
      expect do
        create(:content_embedding, organisation: organisation, embeddable: fragment,
                                   embedding_model: 'text-embedding-3-large')
      end.not_to raise_error
    end
  end

  describe 'vector serialization round-trip (no has_neighbors on the model)' do
    it 'stores and reads back a Ruby array via create!' do
      vec = Array.new(1536) { |i| (i % 7) * 0.01 }
      row = create(:content_embedding, organisation: organisation, embeddable: in_org_fragment,
                                       embedding_dims: 1536, embedding: vec)
      stored = described_class.find(row.id).embedding.to_a
      expect(stored.length).to eq(1536)
      expect(stored.first(3)).to eq(vec.first(3))
    end

    it 'stores and reads back a Ruby array via insert_all (the bulk write path)' do
      fragment = in_org_fragment
      vec = Array.new(1536, 0.25)
      described_class.insert_all([
                                   { organisation_id: organisation.id,
                                     embeddable_type: 'Fragment', embeddable_id: fragment.id,
                                     embedding_provider: 'openai', embedding_model: 'text-embedding-3-small',
                                     embedding_dims: 1536, embedding: vec,
                                     source_hash: described_class.source_hash_for('x'),
                                     indexed: true, embedded_at: Time.current }
                                 ])
      stored = described_class.find_by(embeddable: fragment).embedding.to_a
      expect(stored.length).to eq(1536)
      expect(stored.first).to eq(0.25)
    end

    it 'updates an existing space via upsert_all (the reindexer path)' do
      fragment = in_org_fragment
      base = { organisation_id: organisation.id, embeddable_type: 'Fragment', embeddable_id: fragment.id,
               embedding_provider: 'openai', embedding_model: 'text-embedding-3-small', embedding_dims: 1536,
               indexed: true, embedded_at: Time.current }
      described_class.insert_all([base.merge(embedding: Array.new(1536, 0.1),
                                             source_hash: described_class.source_hash_for('old'))])

      expect do
        described_class.upsert_all(
          [base.merge(embedding: Array.new(1536, 0.9), source_hash: described_class.source_hash_for('new'))],
          unique_by: :idx_content_embeddings_unique_space
        )
      end.not_to change(described_class, :count)

      row = described_class.find_by(embeddable: fragment)
      expect(row.embedding.to_a.first).to eq(0.9)
      expect(row.source_hash).to eq(described_class.source_hash_for('new'))
    end
  end

  describe '.source_hash_for' do
    it 'is a deterministic SHA-256 of the exact text' do
      expect(described_class.source_hash_for('hello')).to eq(Digest::SHA256.hexdigest('hello'))
      expect(described_class.source_hash_for('hello')).to eq(described_class.source_hash_for('hello'))
    end

    it 'is nil-safe (hashes the empty string)' do
      expect(described_class.source_hash_for(nil)).to eq(Digest::SHA256.hexdigest(''))
    end
  end

  describe '.purge_for' do
    it 'deletes exactly the rows of the given type + ids, leaving foreign types/ids' do
      keep_fragment = in_org_fragment
      drop_fragment = in_org_fragment
      keep_row = create(:content_embedding, organisation: organisation, embeddable: keep_fragment)
      drop_row = create(:content_embedding, organisation: organisation, embeddable: drop_fragment)

      described_class.purge_for(embeddable_type: 'Fragment', embeddable_ids: [drop_fragment.id])

      expect(described_class.exists?(drop_row.id)).to be(false)
      expect(described_class.exists?(keep_row.id)).to be(true)
    end

    it 'accepts a Relation subselect as embeddable_ids' do
      fragment = in_org_fragment
      row = create(:content_embedding, organisation: organisation, embeddable: fragment)

      described_class.purge_for(embeddable_type: 'Fragment',
                                embeddable_ids: Fragment.where(id: fragment.id).select(:id))

      expect(described_class.exists?(row.id)).to be(false)
    end
  end

  describe 'presence validations' do
    it 'requires the provenance triple, source_hash, embedding and embedded_at' do
      row = described_class.new(organisation: organisation)
      row.valid?
      expect(row.errors.attribute_names).to include(:embedding_provider, :embedding_model, :embedding_dims,
                                                    :source_hash, :embedding, :embedded_at)
    end
  end

  # The cascade boundary (§3.5): the has_many :content_embeddings, dependent:
  # :delete_all fires on a per-row #destroy, but NOT when the embeddable dies via a
  # parent's callback-free delete_all — that leaves an orphan for the PR-3 GC. Both
  # sides are pinned so nobody mistakes the cascade for a GC substitute.
  describe 'cascade vs. orphan boundary from the embeddable (Fragment)' do
    it 'fragment.destroy takes its sidecar rows with it (dependent: :delete_all cascade)' do
      fragment = in_org_fragment
      row = create(:content_embedding, organisation: organisation, embeddable: fragment)
      expect { fragment.destroy }.to change { described_class.exists?(row.id) }.from(true).to(false)
    end

    it 'a parent delete_all leaves the sidecar rows behind (documented orphan → PR-3 GC)' do
      fragment = in_org_fragment
      row = create(:content_embedding, organisation: organisation, embeddable: fragment)
      note.fragments.delete_all # callback-free parent purge — cascade does NOT fire
      expect(described_class.exists?(row.id)).to be(true)
    end
  end
end
