# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# The `indexed` flag decides whether the read seam can SEE a row
# (Embeddings::NearestNeighbors filters on it). PR 6a introduces the first writers that
# ever clear it, so both directions are pinned here — and, more importantly, the
# ROLL-BACK REGRESSION at the bottom.
#
# That last example is the reason retirement and reactivation ship in the SAME PR
# (sheet §3): with retirement alone, flipping back onto a retired space serves zero
# rows org-wide — silently, and in the exact situation a roll-back exists for. It is
# written as a pair (without reactivation → nothing; with it → hits) so it cannot go
# green for the wrong reason.
RSpec.describe Embeddings::SpaceIndexFlag do
  let(:organisation) { create(:organisation) }
  let(:space)        { create(:embedding_space, organisation: organisation, embedding_model: 'space-a') }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def row_in(model, indexed: true, fragment: create(:fragment, :for_ticket, organisation: organisation))
    create(:content_embedding, organisation: organisation, embeddable: fragment,
                               embedding_provider: 'openai', embedding_model: model,
                               embedding_dims: 1536, indexed: indexed)
  end

  describe 'retirement (indexed → false)' do
    it 'clears the flag on every row of the space and reports the count' do
      # Two identical fixture creations read as an N+1 to Prosopite (uniform org and
      # row lookups), which is a property of the setup, not of the code under test —
      # house pattern, ticket_spec.rb:295.
      Prosopite.pause
      rows = [row_in('space-a'), row_in('space-a')]

      expect(described_class.call(space: space, indexed: false)).to eq(2)
      # One batched read instead of per-row reloads, so the assertion itself adds no
      # queries either.
      expect(ContentEmbedding.where(id: rows.map(&:id)).pluck(:indexed)).to all(be(false))
    end

    it 'leaves rows of OTHER spaces untouched' do
      mine = row_in('space-a')
      other = row_in('space-b')

      described_class.call(space: space, indexed: false)

      expect(mine.reload.indexed).to be(false)
      expect(other.reload.indexed).to be(true)
    end

    it 'leaves another organisation rows untouched (tenant isolation)' do
      foreign_org = create(:organisation, name: 'Other', subdomain: 'other-flag')
      foreign_row = ActsAsTenant.with_tenant(foreign_org) do
        fragment = create(:fragment, :for_ticket, organisation: foreign_org)
        create(:content_embedding, organisation: foreign_org, embeddable: fragment,
                                   embedding_provider: 'openai', embedding_model: 'space-a',
                                   embedding_dims: 1536, indexed: true)
      end

      described_class.call(space: space, indexed: false)

      expect(foreign_row.reload.indexed).to be(true)
    end

    it 'counts only rows it actually changed (a second run is a no-op)' do
      row_in('space-a')

      expect(described_class.call(space: space, indexed: false)).to eq(1)
      expect(described_class.call(space: space, indexed: false)).to eq(0)
    end
  end

  describe 'reactivation (indexed → true)' do
    it 'puts a retired space back into the ANN index' do
      row = row_in('space-a', indexed: false)

      expect(described_class.call(space: space, indexed: true)).to eq(1)
      expect(row.reload.indexed).to be(true)
    end
  end

  # THE reason 6a carries reactivation (sheet §3). Both halves run the same scenario;
  # only the reactivation step differs.
  describe 'roll-back regression: a retired space cannot serve' do
    let(:old_space) { create(:embedding_space, organisation: organisation, embedding_model: 'old') }
    let(:fragment)  { create(:fragment, :for_ticket, organisation: organisation) }

    before do
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai', embedding_model: 'old',
                                 embedding_dims: 1536, indexed: true)
      # Flip away, then retire: the state an org is in after switching to a new model.
      described_class.call(space: old_space, indexed: false)
      organisation.update!(active_embedding_space_id: old_space.id) # roll back the POINTER only
    end

    def hits
      Embeddings::NearestNeighbors.call(embeddable_type: 'Fragment', organisation: organisation,
                                        query_vector: Array.new(1536, 0.1), limit: 5)
    end

    it 'returns NOTHING when only the pointer is rolled back' do
      expect(hits).to be_empty
    end

    it 'returns the rows once the space is reactivated' do
      described_class.call(space: old_space, indexed: true)

      expect(hits.map { |hit| hit.record.id }).to eq([fragment.id])
    end
  end
end
