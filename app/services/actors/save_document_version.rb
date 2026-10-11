# frozen_string_literal: true

# app/services/actors/save_document_version.rb
#
# Creates a new DocumentVersion for an existing Document, promotes it to the
# document's current_version, and schedules asynchronous processing
# (embedding/summary) for the freshly created version.

module Actors
  class SaveDocumentVersion < BaseActor
    def initialize(document:, params:, current_user:)
      super()
      @document = document
      @document_version_params = params
      @current_user = current_user
      @document_version = nil
    end

    def record
      @document
    end

    def perform
      # The document's row lock serialises everything that reads or assigns a
      # version number of this document: a second upload at the same moment, and
      # the stock's numbering (Documents::NumberVersions takes the same lock).
      # Without it two uploads read the same maximum and the unique index throws
      # one of them out, and the backfill, between its clear and its count, would
      # hand this upload's 1 to the oldest stock row and abort (review of #779).
      # lock! reloads, so it runs before anything is read.
      @document.lock!
      @document_version = @document.document_versions.create!(
        number: @document.next_version_number,
        title: @document_version_params['title'],
        description: @document_version_params['description'],
        document_version_file: @document_version_params['document_version_file'],
        # No create_embeddings: the column's default (true) is the answer, see
        # Actors::SaveDocument.
        create_summary: @document_version_params['create_summary'],
        organisation: @document.organisation,
        user: @current_user
      )
      @document.current_version = @document_version
      @document.save!
    end

    def enqueue_jobs
      return unless @document_version

      enqueue_after_commit { DocumentVersionProcessingJob.perform_later(@document_version) }
    end
  end
end
