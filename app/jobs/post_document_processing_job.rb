# frozen_string_literal: true

class PostDocumentProcessingJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "PostDocumentProcessingJob: Record not found - #{error.message}"
  end

  def perform(post_document)
    Rails.logger.info "PostDocumentProcessingJob: Processing PostDocument #{post_document.id}"

    text_extracted = ExtractPlainTextProcessingService.new(
      post_document,
      document_accessor: :post_document_file,
      log_label: 'PostDocumentProcessingService'
    ).process

    enqueue_embedding_processing(post_document) if text_extracted && embeddable?(post_document)
  rescue StandardError => e
    Rails.logger.error "PostDocumentProcessingJob: Error processing PostDocument #{post_document&.id} - #{e.message}"
    raise e
  end

  private

  # Two gates, one question. The opt-in is the document's own; the privacy belongs to the
  # comment it hangs on, and it matters here because NOTHING can read the fragment of a
  # private comment's attachment: the content RAG excludes private comments outright and
  # the app search does not cover attachments. Indexing it would ship the file's text to
  # the embedding provider for a vector with no reader.
  #
  # The extraction above still runs either way: plain_text_version feeds the ticket search,
  # which applies its own privacy rule, and skipping it would take the file away from the
  # one person allowed to see it.
  def embeddable?(post_document)
    post_document.create_embeddings? && !post_document.post&.is_private?
  end

  def enqueue_embedding_processing(post_document)
    EmbeddingProcessingJob.perform_later(
      record_class: PostDocument,
      record_id: post_document.id,
      fragment_association: :fragments
    )
  end
end
