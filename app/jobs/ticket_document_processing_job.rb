# frozen_string_literal: true

class TicketDocumentProcessingJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "TicketDocumentProcessingJob: Record not found - #{error.message}"
  end

  def perform(ticket_document)
    text_extracted = ExtractPlainTextProcessingService.new(
      ticket_document,
      document_accessor: :ticket_document_file,
      log_label: 'TicketDocumentProcessingService'
    ).process

    enqueue_embedding_processing(ticket_document) if text_extracted && ticket_document.create_embeddings?
  rescue StandardError => e
    Rails.logger.error "TicketDocumentProcessingJob: Error processing TicketDocument #{ticket_document&.id} - #{e.message}"
    raise e
  end

  private

  def enqueue_embedding_processing(ticket_document)
    EmbeddingProcessingJob.perform_later(
      record_class: TicketDocument,
      record_id: ticket_document.id,
      fragment_association: :fragments
    )
  end
end
