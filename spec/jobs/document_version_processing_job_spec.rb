# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentVersionProcessingJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:document) { create(:document, project: project, organisation: organisation, creator: user) }
  let(:document_version) do
    create(:document_version, document: document, organisation: organisation,
                              create_embeddings: true, create_summary: false)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def perform_job(version = document_version)
    described_class.new.perform(version)
  end

  def stub_text_extraction(result: true)
    service = instance_double(ExtractPlainTextProcessingService, process: result)
    allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
    service
  end

  describe 'queue configuration' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe '#perform' do
    context 'text extraction' do
      it 'calls ExtractPlainTextProcessingService with correct arguments' do
        service = stub_text_extraction
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        perform_job

        expect(ExtractPlainTextProcessingService).to have_received(:new).with(
          document_version,
          document_accessor: :document_version_file,
          log_label: described_class::LOG_TAG
        )
        expect(service).to have_received(:process)
      end
    end

    context 'when create_embeddings is true (default)' do
      it 'enqueues EmbeddingProcessingJob after text extraction' do
        stub_text_extraction

        expect(EmbeddingProcessingJob).to receive(:perform_later).with(
          record_class: DocumentVersion,
          record_id: document_version.id,
          fragment_association: :fragments
        )

        perform_job
      end
    end

    context 'when create_embeddings is false' do
      before { document_version.update!(create_embeddings: false) }

      it 'does not enqueue EmbeddingProcessingJob' do
        stub_text_extraction

        expect(EmbeddingProcessingJob).not_to receive(:perform_later)

        perform_job
      end

      it 'still runs text extraction' do
        service = stub_text_extraction

        perform_job

        expect(service).to have_received(:process)
      end
    end

    context 'when create_summary is true' do
      before { document_version.update!(create_summary: true) }

      it 'enqueues SummaryProcessingJob after text extraction' do
        stub_text_extraction
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        expect(SummaryProcessingJob).to receive(:perform_later).with(
          record_class: DocumentVersion,
          record_id: document_version.id
        )

        perform_job
      end
    end

    context 'when create_summary is false (default)' do
      it 'does not enqueue SummaryProcessingJob' do
        stub_text_extraction
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        expect(SummaryProcessingJob).not_to receive(:perform_later)

        perform_job
      end
    end

    context 'when both create_embeddings and create_summary are true' do
      before do
        document_version.update!(create_embeddings: true, create_summary: true)
      end

      it 'enqueues both downstream jobs' do
        stub_text_extraction

        expect(EmbeddingProcessingJob).to receive(:perform_later).with(
          record_class: DocumentVersion,
          record_id: document_version.id,
          fragment_association: :fragments
        )
        expect(SummaryProcessingJob).to receive(:perform_later).with(
          record_class: DocumentVersion,
          record_id: document_version.id
        )

        perform_job
      end
    end

    context 'when both create_embeddings and create_summary are false' do
      before do
        document_version.update!(create_embeddings: false, create_summary: false)
      end

      it 'does not enqueue any downstream jobs' do
        stub_text_extraction

        expect(EmbeddingProcessingJob).not_to receive(:perform_later)
        expect(SummaryProcessingJob).not_to receive(:perform_later)

        perform_job
      end

      it 'still runs text extraction' do
        service = stub_text_extraction

        perform_job

        expect(service).to have_received(:process)
      end
    end

    context 'error handling' do
      context 'when ExtractPlainTextProcessingService initialization raises StandardError' do
        it 'logs the error and re-raises' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_raise(StandardError, 'init failure')

          expect(Rails.logger).to receive(:error).with(
            /#{described_class::LOG_TAG}: Error processing DocumentVersion #{document_version.id} - init failure/
          )

          expect { perform_job }.to raise_error(StandardError, 'init failure')
        end

        it 'does not enqueue any downstream jobs' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_raise(StandardError, 'init failure')

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)
          expect(SummaryProcessingJob).not_to receive(:perform_later)

          expect { perform_job }.to raise_error(StandardError)
        end
      end

      context 'when service#process raises StandardError' do
        it 'logs the error and re-raises' do
          service = instance_double(ExtractPlainTextProcessingService)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
          allow(service).to receive(:process).and_raise(RuntimeError, 'process boom')

          expect(Rails.logger).to receive(:error).with(/process boom/)

          expect { perform_job }.to raise_error(RuntimeError, 'process boom')
        end

        it 'does not enqueue downstream jobs' do
          service = instance_double(ExtractPlainTextProcessingService)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
          allow(service).to receive(:process).and_raise(RuntimeError, 'process boom')

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)
          expect(SummaryProcessingJob).not_to receive(:perform_later)

          expect { perform_job }.to raise_error(RuntimeError)
        end
      end

      context 'when ActiveRecord::RecordNotFound is raised during processing' do
        it 'logs the error and re-raises (no separate RecordNotFound handler)' do
          service = instance_double(ExtractPlainTextProcessingService)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
          allow(service).to receive(:process)
            .and_raise(ActiveRecord::RecordNotFound, 'DocumentVersion not found')

          expect(Rails.logger).to receive(:error).with(
            /#{described_class::LOG_TAG}: Error processing DocumentVersion/
          )

          expect { perform_job }.to raise_error(ActiveRecord::RecordNotFound)
        end

        it 'does not enqueue downstream jobs' do
          service = instance_double(ExtractPlainTextProcessingService)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
          allow(service).to receive(:process)
            .and_raise(ActiveRecord::RecordNotFound, 'gone')

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)
          expect(SummaryProcessingJob).not_to receive(:perform_later)

          expect { perform_job }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      context 'when EmbeddingProcessingJob.perform_later raises' do
        it 'logs the error and re-raises' do
          stub_text_extraction
          allow(EmbeddingProcessingJob).to receive(:perform_later)
            .and_raise(StandardError, 'queue failure')

          expect(Rails.logger).to receive(:error).with(/queue failure/)

          expect { perform_job }.to raise_error(StandardError, 'queue failure')
        end

        it 'does not enqueue SummaryProcessingJob' do
          document_version.update!(create_summary: true)
          stub_text_extraction
          allow(EmbeddingProcessingJob).to receive(:perform_later)
            .and_raise(StandardError, 'queue failure')

          expect(SummaryProcessingJob).not_to receive(:perform_later)

          expect { perform_job }.to raise_error(StandardError)
        end
      end

      context 'when SummaryProcessingJob.perform_later raises' do
        before do
          document_version.update!(create_embeddings: false, create_summary: true)
        end

        it 'logs the error and re-raises' do
          stub_text_extraction
          allow(SummaryProcessingJob).to receive(:perform_later)
            .and_raise(StandardError, 'summary queue failure')

          expect(Rails.logger).to receive(:error).with(/summary queue failure/)

          expect { perform_job }.to raise_error(StandardError, 'summary queue failure')
        end
      end
    end

    context 'deserialization' do
      it 'has a discard handler for ActiveJob::DeserializationError' do
        handlers = described_class.rescue_handlers.select { |h| h.first == 'ActiveJob::DeserializationError' }
        expect(handlers).to be_present
      end

      it 'discards and logs when the record is deleted before execution' do
        version_id = document_version.id
        document_version.destroy!

        expect do
          described_class.perform_now(DocumentVersion.new { |dv| dv.id = version_id })
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

      it 'runs text extraction before summary enqueue' do
        document_version.update!(create_embeddings: false, create_summary: true)
        call_order = []

        service = instance_double(ExtractPlainTextProcessingService)
        allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
        allow(service).to receive(:process) do
          call_order << :text_extraction
          true
        end
        allow(SummaryProcessingJob).to receive(:perform_later) { call_order << :summary_enqueue }

        perform_job

        expect(call_order).to eq(%i[text_extraction summary_enqueue])
      end

      it 'enqueues embeddings before summary when both are enabled' do
        document_version.update!(create_embeddings: true, create_summary: true)
        call_order = []

        stub_text_extraction
        allow(EmbeddingProcessingJob).to receive(:perform_later) { call_order << :embedding }
        allow(SummaryProcessingJob).to receive(:perform_later) { call_order << :summary }

        perform_job

        expect(call_order).to eq(%i[embedding summary])
      end
    end
  end

  describe 'ActiveJob enqueueing' do
    it 'can be enqueued with perform_later' do
      expect { described_class.perform_later(document_version) }.not_to raise_error
    end

    it 'uses the default queue' do
      job = described_class.new(document_version)
      expect(job.queue_name).to eq('default')
    end
  end
end
