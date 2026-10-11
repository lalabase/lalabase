# frozen_string_literal: true

# app/services/actors/save_post_documents.rb

module Actors
  class SavePostDocuments < BaseActor
    def initialize(post:, params:)
      super()
      @post = post
      @post_document_params = params
      @new_post_documents = []
    end

    # The batch has no single primary document, so we surface the parent post
    # rather than the (now resolved) post_documents collection.
    def record
      @post
    end

    def perform
      @new_post_documents = create_post_documents(@post, @post_document_params)
    end

    def enqueue_jobs
      @new_post_documents.each do |post_document|
        enqueue_after_commit { PostDocumentProcessingJob.perform_later(post_document) }
      end
    end

    private

    def create_post_documents(post, params)
      new_post_documents = []
      params[:post][:post_document_files]&.each do |file|
          if file.present?
            post_document = PostDocument.create(post: post, post_document_file: file)
            new_post_documents << post_document
          end
        end
      new_post_documents
    end
  end
end
