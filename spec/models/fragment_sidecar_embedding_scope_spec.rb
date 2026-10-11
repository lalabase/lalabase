# frozen_string_literal: true

require 'rails_helper'

# Isolated spec for Fragment.with_sidecar_embedding (embedding v2 PR 5, §3.4.2) — the
# replacement for `where.not(embedding: nil)` on the inline vector column. Since the
# PR-5 write guard that column is a 1536-only lane (NULL for a non-1536 org, dropped
# entirely in PR 7), so any "has an embedding" question has to be asked of the sidecar.
#
# Pinned deliberately as its own unit rather than only through AiSyncStatusService:
# the scope is a public model API now, and its two boundaries (indexed flag, tenant)
# are the ones a later refactor is most likely to lose.
RSpec.describe Fragment, '.with_sidecar_embedding' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def fragment
    note = create(:note, project: project, organisation: organisation)
    create(:fragment, fragmentable: note, organisation: organisation)
  end

  it 'includes a fragment with an indexed sidecar row' do
    record = fragment
    create(:content_embedding, embeddable: record, organisation: organisation, indexed: true)
    expect(described_class.with_sidecar_embedding).to contain_exactly(record)
  end

  it 'excludes a fragment whose sidecar row is not indexed' do
    record = fragment
    create(:content_embedding, embeddable: record, organisation: organisation, indexed: false)
    expect(described_class.with_sidecar_embedding).to be_empty
  end

  # Was "inline vector but NO sidecar row (pre-backfill state)" until PR 7. The inline
  # vector is gone, so the remaining half of that case is the one that still exists and
  # still matters: a fragment nobody ever embedded must not count as embedded.
  it 'excludes a fragment with no sidecar row at all' do
    fragment
    expect(described_class.with_sidecar_embedding).to be_empty
  end

  # Any dimension counts: the question is "was this embedded?", not "is it readable in
  # the current space?" (that one belongs to the alignment gate) — so the scope must
  # carry NO triple filter.
  it 'counts a row of any dimension, with no vector-space filter' do
    record = fragment
    create(:content_embedding, embeddable: record, organisation: organisation,
                               embedding: Array.new(768, 0.1), embedding_dims: 768,
                               embedding_provider: 'openai_compatible', embedding_model: 'nomic-768',
                               indexed: true)
    expect(described_class.with_sidecar_embedding).to contain_exactly(record)
  end

  it 'never lets a foreign organisation sidecar row make a fragment count' do
    record = fragment
    other_org = create(:organisation)
    ActsAsTenant.with_tenant(other_org) do
      create(:content_embedding, embeddable: record, organisation: other_org, indexed: true)
    end
    expect(described_class.with_sidecar_embedding).to be_empty
  end
end
