# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# The job that takes a replaced vector space out of the ANN index after a flip. It had
# NO spec at all (review finding T3, 2026-08-01) — including its guard, whose whole
# purpose is to prevent a silent org-wide outage.
#
# The dangerous case is narrow and easy to miss: flip → roll-back happens faster than
# the queue drains, so by the time this job runs, the space it was told to retire is
# SERVING again. Retiring it then removes every row of the active space from the index
# and search returns nothing, org-wide, without an error.
RSpec.describe Embeddings::RetireSpaceJob do
  let(:organisation) { create(:organisation) }
  let(:space)        { create(:embedding_space, organisation: organisation, embedding_model: 'old') }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def row_in(space_row, indexed: true)
    fragment = create(:fragment, :for_ticket, organisation: organisation)
    create(:content_embedding, organisation: organisation, embeddable: fragment, indexed: indexed,
                               embedding: Array.new(space_row.embedding_dims, 0.01), **space_row.triple)
  end

  it 'retires the rows of the space it is given' do
    row = row_in(space)
    other = create(:embedding_space, organisation: organisation, embedding_dims: 1024)
    organisation.update!(active_embedding_space_id: other.id)

    described_class.perform_now(organisation.id, space.id)

    expect(row.reload.indexed).to be(false)
  end

  # THE guard. Without it the flip → roll-back race de-indexes the serving space.
  it 'does NOT retire a space that is active again by the time it runs' do
    row = row_in(space)
    organisation.update!(active_embedding_space_id: space.id) # rolled back before pickup

    described_class.perform_now(organisation.id, space.id)

    expect(row.reload.indexed).to be(true)
  end

  it 'leaves rows of other spaces alone' do
    keep = create(:embedding_space, organisation: organisation, embedding_dims: 1024)
    keep_row = row_in(keep)
    organisation.update!(active_embedding_space_id: keep.id)

    described_class.perform_now(organisation.id, space.id)

    expect(keep_row.reload.indexed).to be(true)
  end

  describe 'tolerated states (the job must not raise on them)' do
    it 'does nothing when the organisation is gone' do
      expect { described_class.perform_now(SecureRandom.uuid, space.id) }.not_to raise_error
    end

    # The retention GC (PR 6b) may collect the space between flip and pickup.
    it 'does nothing when the space is gone' do
      expect { described_class.perform_now(organisation.id, SecureRandom.uuid) }.not_to raise_error
    end

    # Cross-org id: the lookup is scoped, so this is the "space is gone" case.
    it 'does nothing for a space of another organisation' do
      other_org = create(:organisation, name: 'Other', subdomain: 'other-retire')
      foreign = ActsAsTenant.with_tenant(other_org) { create(:embedding_space, organisation: other_org) }
      foreign_row = ActsAsTenant.with_tenant(other_org) do
        fragment = create(:fragment, :for_ticket, organisation: other_org)
        create(:content_embedding, organisation: other_org, embeddable: fragment, indexed: true,
                                   embedding: Array.new(1536, 0.01), **foreign.triple)
      end

      described_class.perform_now(organisation.id, foreign.id)

      expect(foreign_row.reload.indexed).to be(true)
    end
  end

  # ⚠️ WHAT THIS FILE DOES **NOT** COVER (review finding R-A, 2026-08-01).
  #
  # The examples above pin the GUARD — "a space that is active again is not retired".
  # They do NOT pin the LOCK that the R1 fix added around it. Verified by mutation:
  # reverting `retire_unless_active` to a bare `return if space.active?`, without
  # transaction or FOR UPDATE, leaves this whole file green.
  #
  # That is a real gap, and naming it here is the honest option: proving the lock needs a
  # second database connection flipping the pointer between the lock and the update, and
  # a test built on that timing is more likely to become flaky than to catch a regression.
  # The lock rests on reasoning (see the comment on the job), not on a test — so anyone
  # touching it must know the suite will not stop them.
  it 'reads the pointer from the database rather than from the association it was handed' do
    row = row_in(space)
    organisation.update!(active_embedding_space_id: space.id)
    described_class.perform_now(organisation.id, space.id)

    expect(row.reload.indexed).to be(true)
  end

  it 'runs on the indexing queue (embedding-API work, not default)' do
    expect(described_class.new.queue_name).to eq('indexing')
  end
end
