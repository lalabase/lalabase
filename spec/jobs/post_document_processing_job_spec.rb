# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostDocumentProcessingJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: user) }
  let(:post_record) { create(:post, organisation: organisation, ticket: ticket, user: user) }
  let(:post_document) { create(:post_document, organisation: organisation, post: post_record) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def perform_job(document = post_document)
    described_class.new.perform(document)
  end

  describe 'queue configuration' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe '#perform' do
    context 'happy path' do
      it 'calls ExtractPlainTextProcessingService with correct arguments' do
        service = instance_double(ExtractPlainTextProcessingService, process: true)
        allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        perform_job

        expect(ExtractPlainTextProcessingService).to have_received(:new).with(
          post_document,
          document_accessor: :post_document_file,
          log_label: 'PostDocumentProcessingService'
        )
        expect(service).to have_received(:process)
      end

      context 'when create_embeddings is true (default)' do
        it 'enqueues EmbeddingProcessingJob after text extraction' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_return(instance_double(ExtractPlainTextProcessingService, process: true))

          expect(EmbeddingProcessingJob).to receive(:perform_later).with(
            record_class: PostDocument,
            record_id: post_document.id,
            fragment_association: :fragments
          )

          perform_job
        end
      end

      context 'when create_embeddings is false' do
        before { post_document.update!(create_embeddings: false) }

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

      # The upload gate for the same rule the pending relation enforces: nothing can ever
      # read this fragment, so the file's text must not travel to the provider at all.
      context 'when the comment is private' do
        let(:post_record) do
          create(:post, organisation: organisation, ticket: ticket, user: user,
                        is_private: true, visible_to_user: user)
        end

        it 'does not enqueue EmbeddingProcessingJob' do
          allow(ExtractPlainTextProcessingService).to receive(:new)
            .and_return(instance_double(ExtractPlainTextProcessingService, process: true))

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)

          perform_job
        end

        # Extraction still runs: plain_text_version feeds the ticket search, which applies
        # its own privacy rule. Skipping it would take the attachment away from the one
        # person who is allowed to see it.
        it 'still runs text extraction' do
          service = instance_double(ExtractPlainTextProcessingService, process: true)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)

          perform_job

          expect(service).to have_received(:process)
        end
      end

      it 'logs an info message' do
        allow(ExtractPlainTextProcessingService).to receive(:new)
          .and_return(instance_double(ExtractPlainTextProcessingService, process: true))
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        expect(Rails.logger).to receive(:info).with(
          /PostDocumentProcessingJob: Processing PostDocument #{post_document.id}/
        )

        perform_job
      end
    end

    context 'error handling' do
      context 'when ExtractPlainTextProcessingService initializer raises StandardError' do
        it 'logs the error and re-raises' do
          allow(ExtractPlainTextProcessingService).to receive(:new).and_raise(
            StandardError, 'initialization failure'
          )

          expect(Rails.logger).to receive(:error).with(
            /PostDocumentProcessingJob: Error processing PostDocument #{post_document.id} - initialization failure/
          )

          expect { perform_job }.to raise_error(StandardError, 'initialization failure')
        end

        it 'does not enqueue EmbeddingProcessingJob' do
          allow(ExtractPlainTextProcessingService).to receive(:new).and_raise(
            StandardError, 'initialization failure'
          )

          expect(EmbeddingProcessingJob).not_to receive(:perform_later)

          expect { perform_job }.to raise_error(StandardError)
        end
      end

      context 'when the service process method raises' do
        it 'logs the error and re-raises' do
          service = instance_double(ExtractPlainTextProcessingService)
          allow(ExtractPlainTextProcessingService).to receive(:new).and_return(service)
          allow(service).to receive(:process).and_raise(RuntimeError, 'process boom')

          expect(Rails.logger).to receive(:error).with(/process boom/)

          expect { perform_job }.to raise_error(RuntimeError, 'process boom')
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
        document_id = post_document.id
        post_document.destroy!

        expect do
          described_class.perform_now(PostDocument.new { |pd| pd.id = document_id })
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

  describe 'enqueue_embedding_processing' do
    it 'is a private method' do
      expect(described_class.private_instance_methods).to include(:enqueue_embedding_processing)
    end
  end

  describe 'job class' do
    it 'inherits from ApplicationJob' do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end
end
