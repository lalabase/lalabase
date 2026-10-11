# frozen_string_literal: true

# What: Unit spec for the AI-activation backfill (D2 review decision).
# Type: Service spec — pure revive filter + wiring/delegation contracts.
# Why (philosophy): The revive filter is the decision point that keeps the
#   backfill SAFE: it must revive exactly the two gate-produced states
#   (pending / failed-with-marker) and must NOT retry real failures, whose
#   error message is the admin's only diagnostic. The filter is tested as a
#   pure function on ProjectIndex instances; the enqueue wiring is tested with
#   stubbed collaborators — repo FACTORIES are avoided on purpose, their
#   connect callback (after_create_commit → ProjectIndexerJob) fires at
#   commit-simulation points outside our control and corrupts spy counts.

require 'rails_helper'

RSpec.describe Embeddings::ActivationBackfill do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }

  before { ActsAsTenant.current_tenant = organisation }

  after { ActsAsTenant.current_tenant = nil }

  describe '.revivable_index? (the revive decision)' do
    it 'revives a never-run pending index (connect while disabled, job skipped)' do
      expect(described_class.revivable_index?(ProjectIndex.new(status: 'pending'))).to be(true)
    end

    it 'revives an index the AI gate settled (failed + marker message)' do
      index = ProjectIndex.new(status: 'failed',
                               error_message: Lalabase::Indexer::JobSupport::AI_DISABLED_ERROR_MESSAGE)
      expect(described_class.revivable_index?(index)).to be(true)
    end

    it 'does NOT revive a real failure — its message is the admin diagnostic' do
      index = ProjectIndex.new(status: 'failed', error_message: 'clone failed: auth')
      expect(described_class.revivable_index?(index)).to be(false)
    end

    it 'does NOT revive a ready index (nothing to catch up)' do
      expect(described_class.revivable_index?(ProjectIndex.new(status: 'ready'))).to be(false)
    end

    it 'does NOT revive a missing index' do
      expect(described_class.revivable_index?(nil)).to be(false)
    end
  end

  describe '#call (wiring)' do
    let(:reprocessing) { instance_double(EmbeddingReprocessingService, call: { success: true }) }

    before do
      allow(EmbeddingReprocessingService).to receive(:new).with(organisation).and_return(reprocessing)
      allow(ProjectIndexerJob).to receive(:perform_later)
    end

    def stub_repos(*repos)
      relation = instance_double(ActiveRecord::Relation)
      allow(ProjectRepository).to receive(:where).with(organisation: organisation).and_return(relation)
      allow(relation).to receive(:includes).with(:project_index).and_return(relation)
      allow(relation).to receive(:find_each) { |&block| repos.each(&block) }
    end

    it 'delegates the content backfill to EmbeddingReprocessingService (flag-filtered)' do
      stub_repos
      described_class.call(organisation)
      expect(reprocessing).to have_received(:call)
    end

    it 'enqueues the indexer exactly for revivable repos' do
      revivable = instance_double(ProjectRepository, project_index: ProjectIndex.new(status: 'pending'))
      settled = instance_double(ProjectRepository, project_index: ProjectIndex.new(status: 'ready'))
      stub_repos(revivable, settled)

      described_class.call(organisation)

      expect(ProjectIndexerJob).to have_received(:perform_later).with(revivable)
      expect(ProjectIndexerJob).not_to have_received(:perform_later).with(settled)
    end

    # The caller announces the outcome of the activation, and EmbeddingReprocessingService
    # reports its refusals (AI off, quota exhausted, its own rescue) in the RETURN VALUE
    # rather than by raising. While this method dropped that value, a catch-up that
    # enqueued nothing and one that enqueued five hundred were the same event to every
    # caller, and the flash said "activated" over both.
    it 'returns the reprocessing result rather than the repo-revive side effect' do
      allow(reprocessing).to receive(:call).and_return({ success: true, total_jobs: 7 })
      stub_repos

      expect(described_class.call(organisation)).to eq({ success: true, total_jobs: 7 })
    end

    it 'passes a refusal through unchanged, reason included' do
      allow(reprocessing).to receive(:call).and_return({ success: false, total_jobs: 0, error: 'quota exhausted' })
      stub_repos

      expect(described_class.call(organisation)).to include(success: false, error: 'quota exhausted')
    end

    # Ordering, not decoration: the repo revive must still run when the content half
    # refused, or a quota-paused organisation would quietly lose its index revival too.
    it 'still revives repo indexes when the content half refused' do
      allow(reprocessing).to receive(:call).and_return({ success: false, total_jobs: 0, error: 'nope' })
      revivable = instance_double(ProjectRepository, project_index: ProjectIndex.new(status: 'pending'))
      stub_repos(revivable)

      described_class.call(organisation)

      expect(ProjectIndexerJob).to have_received(:perform_later).with(revivable)
    end

    it 'skips repo revival entirely without the chat beta flag (job would no-op anyway)' do
      organisation.update!(code_indexing_enabled: false)

      described_class.call(organisation)

      expect(ProjectRepository).not_to receive(:where)
      expect(ProjectIndexerJob).not_to have_received(:perform_later)
    end
  end

  # KI-Pakete P4b precondition 3. Nothing else gives a newly activated org an
  # active_embedding_space_id — Actors::FlipEmbeddingModel is the only writer of that
  # column, and it only ever runs for an org that already has a staged switch to finish.
  #
  # Without a pointer the org is not broken, it is INCAPABLE: embedding_space_for falls
  # back to the configured triple, so serving and configuration become the same
  # expression, and a later package change moves reads HARD onto the new empty space.
  describe '#call (the vector-space pointer)' do
    let(:target_space) { create(:embedding_space, organisation: organisation) }

    before do
      allow(EmbeddingReprocessingService).to receive(:new)
        .and_return(instance_double(EmbeddingReprocessingService, call: { success: true }))
      organisation.update_column(:active_embedding_space_id, nil)
    end

    it 'points the organisation at its configured space' do
      allow(Embeddings::EnsureSpace).to receive(:call).with(organisation: organisation)
                                                      .and_return(target_space)

      expect { described_class.call(organisation) }
        .to change { organisation.reload.active_embedding_space_id }.from(nil).to(target_space.id)
    end

    # Re-activation after a deactivate. Overwriting here would repoint a serving org at
    # its CONFIGURED space — which during a staged switch is the half-built one, i.e.
    # exactly the hard switch this slice exists to prevent.
    it 'never overwrites a pointer the organisation already has' do
      existing = create(:embedding_space, organisation: organisation, embedding_model: 'held')
      organisation.update_column(:active_embedding_space_id, existing.id)
      expect(Embeddings::EnsureSpace).not_to receive(:call)

      described_class.call(organisation)

      expect(organisation.reload.active_embedding_space_id).to eq(existing.id)
    end

    # Activation is the GDPR opt-in. EnsureSpace resolves a credential and therefore
    # raises — for an org that activates before one is configured, an ordinary order of
    # operations. It must degrade to "no pointer", never to "no activation".
    it 'still activates when the space cannot be resolved, and says so' do
      allow(Embeddings::EnsureSpace).to receive(:call)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no credential')
      allow(Rails.logger).to receive(:warn)

      expect { described_class.call(organisation) }.not_to raise_error

      expect(organisation.reload.active_embedding_space_id).to be_nil
      expect(Rails.logger).to have_received(:warn)
        .with(/#{organisation.id}.*WITHOUT a vector-space pointer/)
    end

    # Ordering is load-bearing: the vectors reprocessing enqueues land in the CONFIGURED
    # triple, which is the space the pointer now names. Setting it afterwards would leave
    # a window in which they are written into a space nothing points at.
    it 'sets the pointer BEFORE enqueueing the embedding backfill' do
      allow(Embeddings::EnsureSpace).to receive(:call).and_return(target_space)
      pointer_when_reprocessing_ran = nil
      allow(EmbeddingReprocessingService).to receive(:new) do
        pointer_when_reprocessing_ran = organisation.reload.active_embedding_space_id
        instance_double(EmbeddingReprocessingService, call: { success: true })
      end

      described_class.call(organisation)

      expect(pointer_when_reprocessing_ran).to eq(target_space.id)
    end
  end
end
