# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbeddingReprocessingService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  subject { described_class.new(organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  around do |example|
    ActsAsTenant.with_tenant(organisation) do
      example.run
    end
  end

  describe '#call' do
    it 'returns success with zero jobs when no pending embeddings' do
      result = subject.call

      expect(result[:success]).to be true
      expect(result[:total_jobs]).to eq(0)
      expect(result[:message]).to include('0 Embedding-Jobs')
    end

    # GDPR AI opt-in (audit 2026-07-03): the bulk enqueue must refuse up-front
    # instead of queueing hundreds of jobs that each skip individually. The
    # :error key (not :message) is the contract the AI sync status controller
    # reads on failure — a rename there silently blanks the user-facing alert.
    context 'when the organisation has not opted in to AI' do
      let!(:note_pending) { create(:note, project: project, create_embeddings: true, embeddings_creation_flag: nil) }

      before { organisation.update!(ai_enabled: false) }

      it 'returns failure with the localized reason under :error and enqueues nothing' do
        expect(EmbeddingProcessingJob).not_to receive(:perform_later)

        result = subject.call

        expect(result[:success]).to be false
        expect(result[:total_jobs]).to eq(0)
        expect(result[:error]).to eq(I18n.t('shared.ai.disabled_admin_hint'))
      end
    end

    context 'with pending notes' do
      let!(:note_pending) { create(:note, project: project, create_embeddings: true, embeddings_creation_flag: nil) }
      let!(:note_processed) { create(:note, project: project, create_embeddings: true, embeddings_creation_flag: true) }
      let!(:note_disabled) { create(:note, project: project, create_embeddings: false) }

      it 'queues jobs only for pending notes' do
        expect(EmbeddingProcessingJob).to receive(:perform_later).once.with(
          record_class: Note,
          record_id: note_pending.id,
          fragment_association: :fragments
        )

        result = subject.call

        expect(result[:success]).to be true
        expect(result[:total_jobs]).to eq(1)
      end
    end

    context 'with pending tickets' do
      let!(:ticket_pending) { create(:ticket, project: project, embeddings_creation_flag: false) }
      let!(:ticket_processed) { create(:ticket, project: project, embeddings_creation_flag: true) }

      it 'queues jobs for pending tickets' do
        expect(EmbeddingProcessingJob).to receive(:perform_later).once.with(
          record_class: Ticket,
          record_id: ticket_pending.id,
          fragment_association: :fragments
        )

        result = subject.call

        expect(result[:success]).to be true
        expect(result[:total_jobs]).to eq(1)
      end
    end

    context 'with pending posts' do
      let!(:ticket) { create(:ticket, project: project) }
      let!(:post_pending) { create(:post, ticket: ticket, create_embeddings: true, embeddings_creation_flag: nil) }
      let!(:post_processed) { create(:post, ticket: ticket, create_embeddings: true, embeddings_creation_flag: true) }
      let!(:post_disabled) { create(:post, ticket: ticket, create_embeddings: false) }

      it 'queues jobs only for pending posts' do
        expect(EmbeddingProcessingJob).to receive(:perform_later).exactly(2).times # post_pending + ticket (tickets are always enabled)

        result = subject.call

        expect(result[:success]).to be true
        expect(result[:total_jobs]).to eq(2)
      end
    end

    # Closes a pre-existing coverage gap (no dedicated DocumentVersion context existed)
    # that the enqueue_pending extraction now touches: the join is only on the
    # document's CURRENT version, and create_embeddings must be true.
    context 'with pending document versions' do
      let!(:document) { create(:document, project: project) }
      let!(:version_pending) do
        v = create(:document_version, document: document, create_embeddings: true, embeddings_creation_flag: nil)
        document.update!(current_version: v)
        v
      end

      it 'queues a job for the pending current document version' do
        expect(EmbeddingProcessingJob).to receive(:perform_later).once.with(
          record_class: DocumentVersion, record_id: version_pending.id, fragment_association: :fragments
        )

        result = subject.call

        expect(result[:success]).to be true
        expect(result[:total_jobs]).to eq(1)
      end
    end

    context 'with pending documentation pages (Slice 3 — sixth wiring point)' do
      let!(:set) { create(:documentation_set, project: project) }
      let!(:page_pending) { create(:documentation_page, documentation_set: set, embeddings_creation_flag: nil) }
      let!(:page_processed) { create(:documentation_page, documentation_set: set, embeddings_creation_flag: true) }
      let!(:page_removed) do
        create(:documentation_page, documentation_set: set, embeddings_creation_flag: nil, removed_at: Time.current)
      end

      it 'queues a job only for the present, un-embedded page' do
        expect(EmbeddingProcessingJob).to receive(:perform_later).once.with(
          record_class: DocumentationPage, record_id: page_pending.id, fragment_association: :fragments
        )

        result = subject.call

        expect(result[:success]).to be true
        expect(result[:total_jobs]).to eq(1)
      end

      it 'never re-embeds a soft-removed page (its fragments were purged on removal)' do
        subject.call

        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
          .with(hash_including(record_id: page_removed.id))
      end

      it 'never re-embeds an already-processed page' do
        subject.call

        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
          .with(hash_including(record_id: page_processed.id))
      end
    end

    context 'with mixed pending content' do
      let!(:note_pending) { create(:note, project: project, create_embeddings: true, embeddings_creation_flag: nil) }
      let!(:ticket_pending) { create(:ticket, project: project, embeddings_creation_flag: false) }
      let!(:ticket2) { create(:ticket, project: project, embeddings_creation_flag: false) }
      let!(:post_pending) { create(:post, ticket: ticket2, create_embeddings: true, embeddings_creation_flag: nil) }

      it 'queues jobs for all pending content types' do
        expect(EmbeddingProcessingJob).to receive(:perform_later).exactly(4).times # NOTE: + 2 tickets + post

        result = subject.call

        expect(result[:success]).to be true
        expect(result[:total_jobs]).to eq(4)
      end
    end

    context 'when an error occurs' do
      before do
        allow(Embeddings::PendingEmbeddings).to receive(:relations_by_model)
          .and_raise(StandardError.new('Database error'))
      end

      it 'returns failure result with error message' do
        result = subject.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Database error')
        expect(result[:total_jobs]).to eq(0)
      end
    end
  end

  # S3 KI-Kontingent (decision 5A, test 30): the catch-up is quota-aware — it must
  # NOT enqueue a job storm when the org's budget is exhausted.
  describe 'quota-aware catch-up' do
    let(:organisation) do
      create(:organisation, ai_quota_credits_override: 0, ai_quota_buffer_override: 0)
    end
    let!(:credential) { create(:ai_credential, :active, provider: 'openai', included_in_quota: true) }
    let!(:pending_note) do
      create(:note, project: project, organisation: organisation, create_embeddings: true,
                    plain_text_version: 'pending content', embeddings_creation_flag: false)
    end

    before { Rails.cache.clear }

    it 'bails without enqueuing when the budget is exhausted (rest stays pending)' do
      expect(EmbeddingProcessingJob).not_to receive(:perform_later)
      result = described_class.new(organisation).call
      expect(result[:success]).to be false
      expect(result[:total_jobs]).to eq(0)
    end

    it 'proceeds normally once the budget is available again' do
      organisation.update!(ai_quota_credits_override: 1000)
      allow(EmbeddingProcessingJob).to receive(:perform_later)
      result = described_class.new(organisation).call
      expect(result[:success]).to be true
      expect(result[:total_jobs]).to be >= 1
    end
  end
end
