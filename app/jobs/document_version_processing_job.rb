# frozen_string_literal: true

class DocumentVersionProcessingJob < ApplicationJob
  queue_as :default

  LOG_TAG = 'DocumentVersionProcessingJob'

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "#{LOG_TAG}: Record not found - #{error.message}"
  end

  def perform(document_version)
    Rails.logger.info "#{LOG_TAG}: Processing DocumentVersion #{document_version.id}"

    text_extracted = ExtractPlainTextProcessingService.new(
      document_version,
      document_accessor: :document_version_file,
      log_label: LOG_TAG
    ).process

    enqueue_embedding_processing(document_version) if text_extracted && document_version.create_embeddings?
    enqueue_summary_processing(document_version) if document_version.create_summary?
  rescue StandardError => e
    Rails.logger.error "#{LOG_TAG}: Error processing DocumentVersion #{document_version&.id} - #{e.message}"
    raise
  end

  private

  def enqueue_embedding_processing(document_version)
    EmbeddingProcessingJob.perform_later(
      record_class: DocumentVersion,
      record_id: document_version.id,
      fragment_association: :fragments
    )
  end

  def enqueue_summary_processing(document_version)
    SummaryProcessingJob.perform_later(
      record_class: DocumentVersion,
      record_id: document_version.id
    )
  end
end
