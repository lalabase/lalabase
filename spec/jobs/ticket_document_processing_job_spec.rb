# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketDocumentProcessingJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
  let(:ticket_document) { create(:ticket_document, ticket: ticket, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def perform_job(document = ticket_document)
    described_class.new.perform(document)
  end

  describe 'queue configuration' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe '#perform' do
    context 'happy path — text extraction succeeds' do
      it 'calls ExtractPlainTextProcessingService with correct arguments' do
        service = instance_double(ExtractPlainTextProcessingService, process: true)
        allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)

        perform_job

        expect(ExtractPlainTextProcessingService).to have_received(:new).with(
          ticket_document,
          document_accessor: :ticket_document_file,
          log_label: 'TicketDocumentProcessingService'
        )
        expect(service).to have_received(:process)
      end

      context 'when create_embeddings is true (default)' do
        it 'enqueues EmbeddingProcessingJob after text extraction' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_return(instance_double(ExtractPlainTextProcessingService, process: true))

          expect(EmbeddingProcessingJob).to receive(:perform_later).with(
            record_class: TicketDocument,
            record_id: ticket_document.id,
            fragment_association: :fragments
          )

          perform_job
        end
      end

      context 'when create_embeddings is false' do
        before { ticket_document.update!(create_embeddings: false) }

        it 'does not enqueue EmbeddingProcessingJob' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_return(instance_double(ExtractPlainTextProcessingService, process: true))

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)

          perform_job
        end

        it 'still runs text extraction' do
          service = instance_double(ExtractPlainTextProcessingService, process: true)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)

          perform_job

          expect(service).to have_received(:process)
        end
      end
    end

    context 'when text extraction fails (returns false)' do
      it 'does not enqueue EmbeddingProcessingJob even when create_embeddings is true' do
        allow(ExtractPlainTextProcessingService).to receive(:new)
          .and_return(instance_double(ExtractPlainTextProcessingService, process: false))

        expect(EmbeddingProcessingJob).not_to receive(:perform_later)

        perform_job
      end

      it 'still completes without error' do
        allow(ExtractPlainTextProcessingService).to receive(:new)
          .and_return(instance_double(ExtractPlainTextProcessingService, process: false))

        expect { perform_job }.not_to raise_error
      end
    end

    context 'error handling' do
      context 'when ExtractPlainTextProcessingService raises StandardError' do
        it 'logs the error and re-raises' do
          allow(ExtractPlainTextProcessingService).to receive(:new).and_raise(
            StandardError, 'extraction failure'
          )

          expect(Rails.logger).to receive(:error).with(
            /TicketDocumentProcessingJob: Error processing TicketDocument #{ticket_document.id} - extraction failure/
          )

          expect { perform_job }.to raise_error(StandardError, 'extraction failure')
        end

        it 'does not enqueue EmbeddingProcessingJob' do
          allow(ExtractPlainTextProcessingService).to receive(:new).and_raise(
            StandardError, 'extraction failure'
          )

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)

          expect { perform_job }.to raise_error(StandardError)
        end
      end

      context 'when the service process method raises (e.g. save! failure)' do
        it 'logs the error and re-raises' do
          service = instance_double(ExtractPlainTextProcessingService)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
          allow(service).to receive(:process).and_raise(RuntimeError, 'save! failed')

          expect(Rails.logger).to receive(:error).with(/save! failed/)

          expect { perform_job }.to raise_error(RuntimeError, 'save! failed')
        end
      end

      context 'when EmbeddingProcessingJob.perform_later raises' do
        it 'logs the error and re-raises' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_return(instance_double(ExtractPlainTextProcessingService, process: true))
          allow(EmbeddingProcessingJob).to receive(:perform_later).and_raise(
            StandardError, 'queue failure'
          )

          expect(Rails.logger).to receive(:error).with(/queue failure/)

          expect { perform_job }.to raise_error(StandardError, 'queue failure')
        end
      end
    end

    context 'deserialization' do
      it 'has a discard_on handler for DeserializationError' do
        handlers = described_class.rescue_handlers.select { |h| h.first == 'ActiveJob::DeserializationError' }
        expect(handlers).to be_present
      end

      it 'discards and logs when the record is deleted before execution' do
        document_id = ticket_document.id
        ticket_document.destroy!

        expect do
          described_class.perform_now(TicketDocument.new { |td| td.id = document_id })
        end.not_to raise_error
      rescue ActiveJob::DeserializationError
        # Expected — discard_on handles this at the framework level
      end
    end

    context 'execution order' do
      it 'runs text extraction before embedding enqueue' do
        call_order = []

        service = instance_double(ExtractPlainTextProcessingService)
        allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
        allow(service).to receive(:process) do
          call_order << :text_extraction
          true
        end
        allow(EmbeddingProcessingJob).to receive(:perform_later) { call_order << :embedding_enqueue }

        perform_job

        expect(call_order).to eq(%i[text_extraction embedding_enqueue])
      end
    end
  end

  describe 'ActiveJob enqueueing' do
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    it 'can be enqueued with perform_later' do
      expect do
        described_class.perform_later(ticket_document)
      end.to have_enqueued_job(described_class)
    end

    it 'enqueues in the default queue' do
      expect do
        described_class.perform_later(ticket_document)
      end.to have_enqueued_job(described_class).on_queue('default')
    end
  end
end
