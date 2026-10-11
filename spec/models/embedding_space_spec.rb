# frozen_string_literal: true

# == Schema Information
#
# Table name: embedding_spaces
#
#  id                 :uuid             not null, primary key
#  access_token       :text
#  api_base           :string
#  embedding_dims     :integer          not null
#  embedding_model    :string           not null
#  embedding_provider :string           not null
#  retired_at         :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_credential_id   :uuid
#  organisation_id    :uuid             not null
#  organization_id    :string
#
# Indexes
#
#  idx_embedding_spaces_unique_triple          (organisation_id,embedding_provider,embedding_model,embedding_dims) UNIQUE
#  index_embedding_spaces_on_ai_credential_id  (ai_credential_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_credential_id => ai_credentials.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id) ON DELETE => cascade
#
require 'rails_helper'

# What this file protects
# -----------------------
# 1. The credential snapshot is ENCRYPTED AT REST. Checked by reading the RAW column
#    through SQL, not through the attribute — a spec that only asserts "the token round
#    trips" passes on an UNENCRYPTED column too, which is exactly how the
#    Admin::AiCredential plain-text finding survived.
# 2. The triple is the vector-space key: unique per org, hard-validated, and shaped
#    identically to what Factory.embedding_space_for returns and ContentEmbedding rows
#    are stamped with — a drift there is invisible until retrieval returns nothing.
# 3. Tenant isolation, and that deleting an org takes its spaces with it.
RSpec.describe EmbeddingSpace do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'credential encryption' do
    it 'stores access_token encrypted — the raw column is NOT the plain token' do
      space = create(:embedding_space, :byok, organisation: organisation, access_token: 'sk-plain-secret')

      raw = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ['SELECT access_token FROM embedding_spaces WHERE id = ?', space.id]
        )
      )

      expect(raw).to be_present
      expect(raw).not_to eq('sk-plain-secret')
      expect(raw).not_to include('sk-plain-secret')
    end

    it 'decrypts the token back through the attribute (round trip)' do
      space = create(:embedding_space, :byok, organisation: organisation, access_token: 'sk-plain-secret')

      expect(described_class.find(space.id).access_token).to eq('sk-plain-secret')
    end

    # NULL credentials are a MEANING, not an absence: "resolve the system credential".
    # Copying the system token in would freeze a rotating secret into every space.
    it 'keeps a system-path space with all credential columns nil' do
      space = create(:embedding_space, organisation: organisation)

      expect([space.access_token, space.api_base, space.organization_id]).to all(be_nil)
    end
  end

  describe 'validations' do
    it 'accepts every supported dimension' do
      Organisation::SUPPORTED_DIMS.each do |dims|
        space = build(:embedding_space, organisation: organisation, embedding_dims: dims,
                                        embedding_model: "m-#{dims}")
        expect(space).to be_valid, "expected #{dims} to be accepted"
      end
    end

    # Boundary n-1/n+1 around the allowlist, plus nil: unlike Organisation#embedding_dims
    # this column has NO allow_nil — an org column may mean "unconfigured", a SPACE row
    # describes an already-resolved space and cannot lack a dimension.
    it 'rejects an unsupported dimension' do
      expect(build(:embedding_space, organisation: organisation, embedding_dims: 512)).not_to be_valid
      expect(build(:embedding_space, organisation: organisation, embedding_dims: 4096)).not_to be_valid
    end

    it 'rejects a nil dimension (no allow_nil here, unlike the org column)' do
      expect(build(:embedding_space, organisation: organisation, embedding_dims: nil)).not_to be_valid
    end

    it 'requires provider and model' do
      expect(build(:embedding_space, organisation: organisation, embedding_provider: nil)).not_to be_valid
      expect(build(:embedding_space, organisation: organisation, embedding_model: nil)).not_to be_valid
    end

    it 'is unique per organisation and triple' do
      create(:embedding_space, organisation: organisation)

      expect { create(:embedding_space, organisation: organisation) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The unique index is on the TRIPLE, so the same model at a different dimension is
    # a DIFFERENT space — that is the whole reason dims is a first-class field.
    it 'allows the same provider/model at a different dimension' do
      create(:embedding_space, organisation: organisation, embedding_dims: 1536)

      expect { create(:embedding_space, organisation: organisation, embedding_dims: 1024) }
        .to change(described_class, :count).by(1)
    end

    # The unique index is scoped to the ORG, so two tenants holding the identical
    # triple must not collide. Asserted via the created row rather than a global
    # count: `count` runs under the ambient tenant scope and would measure isolation
    # instead of the uniqueness rule this example is about.
    it 'allows another organisation to hold the identical triple' do
      mine = create(:embedding_space, organisation: organisation)
      other = create(:organisation, name: 'Other', subdomain: 'other-space')

      theirs = ActsAsTenant.with_tenant(other) { create(:embedding_space, organisation: other) }

      expect(theirs.triple).to eq(mine.triple)
      expect(theirs.id).not_to eq(mine.id)
    end

    it 'hides another organisation spaces from the ambient tenant scope' do
      other = create(:organisation, name: 'Other2', subdomain: 'other-space-2')
      ActsAsTenant.with_tenant(other) { create(:embedding_space, organisation: other) }

      expect(described_class.count).to eq(0)
    end
  end

  describe '#triple' do
    it 'has exactly the shape Factory.embedding_space_for returns' do
      space = create(:embedding_space, organisation: organisation, embedding_provider: 'openai',
                                       embedding_model: 'm', embedding_dims: 1024)

      expect(space.triple).to eq(embedding_provider: 'openai', embedding_model: 'm',
                                 embedding_dims: 1024)
    end

    # If these keys ever drift apart, every comparison between a stored row and a
    # resolved space silently becomes false and retrieval returns nothing.
    it 'matches the key set ContentEmbedding rows are stamped with' do
      space = create(:embedding_space, organisation: organisation)

      expect(space.triple.keys).to match_array(%i[embedding_provider embedding_model embedding_dims])
      expect(ContentEmbedding.column_names).to include(*space.triple.keys.map(&:to_s))
    end
  end

  describe '#content_embeddings' do
    it 'returns the rows carrying this space triple, and no others' do
      space = create(:embedding_space, organisation: organisation, embedding_model: 'mine')
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      mine = create(:content_embedding, organisation: organisation, embeddable: fragment,
                                        embedding_provider: 'openai', embedding_model: 'mine',
                                        embedding_dims: 1536)
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai', embedding_model: 'other',
                                 embedding_dims: 1536)

      expect(space.content_embeddings.pluck(:id)).to eq([mine.id])
    end
  end

  describe '#active?' do
    it 'is true only for the space the org pointer names' do
      space = create(:embedding_space, organisation: organisation)
      other = create(:embedding_space, organisation: organisation, embedding_dims: 1024)
      organisation.update!(active_embedding_space_id: space.id)

      expect(space.reload).to be_active
      expect(other.reload).not_to be_active
    end
  end

  describe 'organisation deletion' do
    # Circular FK (organisations.active_embedding_space_id ↔ embedding_spaces.organisation_id):
    # the pointer is ON DELETE SET NULL precisely so this does not deadlock the delete
    # (sheet fork F3). Without that choice this test would raise.
    it 'takes the spaces with it, even while one of them is the active pointer' do
      space = create(:embedding_space, organisation: organisation)
      organisation.update!(active_embedding_space_id: space.id)

      expect { organisation.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  # Review A4: this scope decides WHICH space the retention GC keeps — the single most
  # safety-critical ordering of PR 6b — so the full order, including the ties Postgres
  # would otherwise return in arbitrary order, is pinned at the model. Ties are not
  # exotic: every space from before retired_at existed sits at NULL, and two flips can
  # share a second.
  describe '.by_retirement_recency' do
    # Insertion order is DELIBERATELY the reverse of the expected order: Postgres
    # without the tie-break tends to return heap (insertion) order, so inserting in the
    # expected order would let the tie-break mutation pass by accident. Inserted
    # reversed, only the ORDER BY itself can produce the expected sequence.
    it 'orders retired-desc with NULLs last, breaking ties by created_at then id' do
      spaces = nil
      Prosopite.pause do
        tie = 2.days.ago
        spaces = {
          null_old: create(:embedding_space, organisation: organisation,
                                             embedding_model: 'null-old', retired_at: nil),
          null_new: create(:embedding_space, organisation: organisation,
                                             embedding_model: 'null-new', retired_at: nil),
          tied_old: create(:embedding_space, organisation: organisation,
                                             embedding_model: 'tied-old', retired_at: tie),
          tied_new: create(:embedding_space, organisation: organisation,
                                             embedding_model: 'tied-new', retired_at: tie),
          fresh: create(:embedding_space, organisation: organisation,
                                          embedding_model: 'fresh', retired_at: 1.hour.ago)
        }
        # Updated old-before-new as well: update_column rewrites the heap tuple, so
        # updating in expected order would re-create insertion order and mask a
        # missing tie-break exactly like ordered inserts would.
        spaces[:tied_old].update_column(:created_at, 9.days.ago)
        spaces[:tied_new].update_column(:created_at, 3.days.ago)
        spaces[:null_old].update_column(:created_at, 10.days.ago)
        spaces[:null_new].update_column(:created_at, 1.day.ago)
      end

      expect(described_class.by_retirement_recency.map(&:embedding_model))
        .to eq(%w[fresh tied-new tied-old null-new null-old])
    end
  end
end
