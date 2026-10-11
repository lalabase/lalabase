# frozen_string_literal: true

# What: S4 of doc/fragment_einbettung_entkopplung_plan.md — "ausstehend" must be able to
#   reach zero.
# Type: Service + read-model spec across EmbeddingProcessingService and
#   Embeddings::IndexHealth, because the two halves of the defect live on either side.
# Why (philosophy): The pending figure is an instruction to the admin: something is owed,
#   press the button. Two states made it permanent instead, and in both the button was
#   powerless. Measured in production on 2026-08-31, after the fragment/embedding split
#   shipped: six DocumentVersions with no file and no extractable text, sitting pending
#   since 08/2025, and seventeen AI-off organisations carrying 68 records between them.
#   Neither was broken. The counter was answering a question nobody had asked.
# Contract: a record the pipeline will never index settles as done; an organisation whose
#   opt-in is off is reported as paused rather than as a backlog in progress.

require 'rails_helper'

RSpec.describe 'The pending counter can reach zero' do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  after { ActsAsTenant.current_tenant = nil }

  around { |example| ActsAsTenant.with_tenant(organisation) { example.run } }

  describe 'a record with nothing to index' do
    # The production shape: a document version whose file never arrived, so
    # ExtractPlainTextProcessingService had nothing to write. It is not an embedding
    # failure and no retry can change it.
    def note_without_text
      note = create(:note, project: project, organisation: organisation, creator: user,
                           create_embeddings: true, content: 'wird gleich geleert')
      note.update_columns(plain_text_version: nil, embeddings_creation_flag: nil)
      note.reload
    end

    it 'settles as done instead of waiting forever' do
      note = note_without_text

      EmbeddingProcessingService.new(note).process

      expect(note.reload.embeddings_creation_flag).to be(true)
    end

    it 'leaves the pending list, so a catch-up run stops picking it up' do
      note = note_without_text

      expect { EmbeddingProcessingService.new(note).process }
        .to change { Embeddings::PendingEmbeddings.relations_by_model[Note].count }.from(1).to(0)
    end

    it 'stops being counted as outstanding work' do
      note_without_text

      expect { EmbeddingProcessingService.new(Note.last).process }
        .to change { Embeddings::IndexHealth.call(organisation: organisation).pending }.from(1).to(0)
    end

    it 'writes no fragment, because there is nothing to write' do
      note = note_without_text

      expect { EmbeddingProcessingService.new(note).process }.not_to change(Fragment, :count)
    end

    # The verdict does not depend on the opt-in: the gate governs a transfer, and there is
    # nothing here to transfer. Gated, it would recreate the permanent count for exactly
    # the organisations that can never resolve it.
    it 'settles the same way for an AI-off organisation' do
      organisation.update!(ai_enabled: false)
      note = note_without_text

      EmbeddingProcessingService.new(note).process

      expect(note.reload.embeddings_creation_flag).to be(true)
    end

    # Self-healing, and the reason marking done is safe: content arriving later comes
    # through a save, and the save enqueues a fresh job that supersedes this verdict.
    it 'is indexed normally once text arrives' do
      note = note_without_text
      EmbeddingProcessingService.new(note).process
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(
        instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil,
                                                       embed_with_usage: { embedding: Array.new(1536) { 0.1 }, total_tokens: 5 },
                                                       provider_name: 'openai',
                                                       default_embedding_model: 'text-embedding-3-small',
                                                       expected_embedding_dims: 1536)
      )

      note.update!(content: 'Jetzt steht hier ein Quastenflosser drin.')

      expect { EmbeddingProcessingService.new(note.reload).process }.to change(Fragment, :count)
    end
  end

  describe 'an organisation whose AI is switched off' do
    before do
      organisation.update!(ai_enabled: false)
      create(:note, project: project, organisation: organisation, creator: user,
                    create_embeddings: true, content: 'Inhalt ohne Einwilligung',
                    embeddings_creation_flag: nil)
    end

    it 'is reported as paused, not as work in progress' do
      health = Embeddings::IndexHealth.call(organisation: organisation)

      expect(health.paused?).to be(true)
      expect(health.working?).to be(false)
    end

    it 'still counts the records, because the number itself is true' do
      expect(Embeddings::IndexHealth.call(organisation: organisation).pending).to eq(1)
    end

    # The selection must NOT learn about the switch: Embeddings::ActivationBackfill walks
    # exactly this relation the moment somebody switches AI on, so a record hidden here
    # would never be caught up. The fix was a display question and has to stay one.
    it 'keeps the record on the pending relation for the day AI is switched on' do
      expect(Embeddings::PendingEmbeddings.relations_by_model[Note].count).to eq(1)
    end

    it 'reports work in progress again once the switch is thrown' do
      organisation.update!(ai_enabled: true)

      expect(Embeddings::IndexHealth.call(organisation: organisation).working?).to be(true)
    end
  end
end
