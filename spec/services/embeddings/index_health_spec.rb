# frozen_string_literal: true

# What: Unit spec for Embeddings::IndexHealth, the hub's indexing figure.
# Type: Service spec — counting rules + tenant isolation.
# Why (philosophy): This service exists to stay inside the hub's query budget (§3.3 of
#   doc/ki_bereich_navigation_plan.md), which it pays for by leaving ActiveRecord behind:
#   one raw UNION instead of one relation per type. That trade has a price — acts_as_tenant is
#   not in play, so the organisation is bound by hand on every branch. The request specs
#   cannot see a mistake there, because they only ever have one organisation: dropping
#   the tenant filter left all of them green (measured). This file is where that failure
#   has to be caught.
# Contract: counts outstanding and failed work across every type in
#   Embeddings::ContentTypes,
#   for THIS organisation only; on request it also names the vector space those counts
#   describe, and never raises over one it cannot resolve.

require 'rails_helper'

RSpec.describe Embeddings::IndexHealth do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user) }

  def health
    described_class.call(organisation: organisation)
  end

  it 'reports a clean slate as clear' do
    expect(health).to have_attributes(pending: 0, failed: 0)
    expect(health.clear?).to be(true)
  end

  it 'counts content that has not been processed yet as outstanding' do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation,
                    create_embeddings: true, embeddings_creation_flag: nil)
    end

    expect(health).to have_attributes(pending: 1, failed: 0)
    expect(health.working?).to be(true)
  end

  # NULL and FALSE both mean "not done". A `= FALSE` predicate would silently drop the
  # NULLs, which on a fresh corpus is nearly everything — the card would then read
  # "aktuell" over an entirely unindexed organisation.
  it 'treats an explicit false flag as outstanding, exactly like a NULL' do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation,
                    create_embeddings: true, embeddings_creation_flag: false)
    end

    expect(health.pending).to eq(1)
  end

  it 'counts an error as failed rather than as outstanding' do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation,
                    create_embeddings: true, embedding_creation_error: 'boom')
    end

    expect(health).to have_attributes(pending: 0, failed: 1)
    expect(health.clear?).to be(false)
    expect(health.working?).to be(false)
  end

  # The opt-in column is the difference between "not embedded" and "not to be embedded".
  # Without it the card would report a permanent backlog for every organisation that
  # deliberately keeps notes out of the index.
  it 'ignores content that was never meant to be embedded' do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation, create_embeddings: false)
    end

    expect(health.pending).to eq(0)
  end

  # Tickets carry no opt-in column — every ticket is embedded. Pinned because the
  # branch for them is the one that reads `TRUE` instead of a column, and a copy-paste
  # of a neighbouring branch would compile, run, and quietly count nothing.
  it 'counts tickets, which have no opt-in column at all' do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation) }

    expect(health.pending).to eq(1)
  end

  # ⚠️ THE reason this file exists. Raw SQL means no default scope, so every branch of
  # the UNION binds organisation_id by hand. Removing that filter leaves every request
  # spec green — they have one organisation — while the card would report a foreign
  # tenant's backlog as this organisation's own.
  #
  # EVERY branch carries foreign content, and that is the point rather than thorough-
  # ness: the first version of this example covered three of the four types there were,
  # so dropping the tenant filter from the document_versions branch alone kept every
  # example green (measured). One unrepresented branch is one branch whose filter nobody
  # is holding — and the list grew to nine while this example stayed at four. It is
  # derived now, so a tenth type arrives here with its own foreign record.
  it 'never counts another organisation, in any branch' do
    other = create(:organisation)
    other_project = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
    # The builder plants a pending, opted-in record of each type, current-version join
    # for documents included — a version the document does not point at would be skipped
    # for a reason that has nothing to do with the tenant, which would make that branch
    # of the example silently vacuous.
    Embeddings::ContentTypes.entries.each do |entry|
      create_pending_record(entry.key, organisation: other, project: other_project, user: user)
    end
    # One failed record on top: `failed` is a SECOND filter over the same branch and
    # would read zero on pending-only content whatever the tenant term did.
    ActsAsTenant.with_tenant(other) do
      create(:note, project: other_project, organisation: other,
                    create_embeddings: true, embedding_creation_error: 'boom')
    end

    expect(health).to have_attributes(pending: 0, failed: 0)
  end

  # The space half (S4, §3.5 Fortschreibung). "12 ausstehend" stopped being a complete
  # statement the day an organisation could hold more than one vector space — but only
  # the Indexierung page can afford the extra read, so it is opt-in and the hub stays at
  # its nine queries.
  describe 'the vector space the counts describe' do
    let(:space) do
      ActsAsTenant.with_tenant(organisation) do
        create(:embedding_space, organisation: organisation,
                                 embedding_provider: 'openai',
                                 embedding_model: 'text-embedding-3-small',
                                 embedding_dims: 1536)
      end
    end

    # The default is the contract, not a convenience: the hub calls this class without
    # the flag and its query budget is already at the ceiling. A default of true would
    # break that page from over here, where nobody would look.
    it 'is not resolved unless it was asked for' do
      space
      organisation.update!(active_embedding_space: space)

      expect(Lalabase::Llm::Factory).not_to receive(:embedding_space_for)
      expect(health.space).to be_nil
    end

    it 'answers from the POINTER, which is what the read seam serves from' do
      space
      organisation.update!(active_embedding_space: space)

      expect(described_class.call(organisation: organisation, with_space: true).space)
        .to eq(embedding_provider: 'openai', embedding_model: 'text-embedding-3-small',
               embedding_dims: 1536)
    end

    # ⚠️ The point of the whole space branch. During a staged switch the organisation's
    # own embedding_* columns already describe the space being BUILT, while the counts
    # above describe the one still being READ. Deriving the label from those columns
    # would label the backlog with the wrong space — precisely on the page an admin
    # opens because numbers are moving.
    it 'names the space being served, not the one being built' do
      space
      organisation.update!(active_embedding_space: space, embedding_provider: 'google',
                           embedding_model: 'text-embedding-004', embedding_dims: 768)

      expect(described_class.call(organisation: organisation, with_space: true).space)
        .to include(embedding_model: 'text-embedding-3-small')
    end

    # A status page must not 500 over the very fault it would report. Same posture as
    # Embeddings::SwitchProgress: say nothing about the space, keep the numbers.
    it 'stays silent about an unresolvable space instead of raising' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Provider::Error, 'no credential')

      result = described_class.call(organisation: organisation, with_space: true)

      expect(result.space).to be_nil
      expect(result.pending).to eq(0)
    end
  end
end
