# frozen_string_literal: true

# app/services/actors/save_document.rb
#
# Saves a Document — one entry point for its whole write lifecycle.
#   - create (id nil): build the Document together with its first DocumentVersion
#     (from nested document_versions_attributes), promote it to current_version
#     and schedule asynchronous processing for that version.
#   - update (id given): apply the params to the existing Document. title and
#     description delegate to the current_version (Document#title=/#description=),
#     tag_list assignment syncs the tags. No processing job on update — the
#     version content is unchanged (a new version goes through SaveDocumentVersion).

module Actors
  class SaveDocument < BaseActor
    def initialize(project:, params:, current_user:, id: nil)
      super()
      @document = find_or_build(
        project.documents,
        id,
        { project: project, organisation: project.organisation }
      )
      @document_params = params
      @current_user = current_user
      @new_version = nil
    end

    def record
      @document
    end

    def perform
      if @document.new_record?
        create_with_first_version
      else
        @document.update!(@document_params)
      end
    end

    def enqueue_jobs
      return unless @new_version

      enqueue_after_commit { DocumentVersionProcessingJob.perform_later(@new_version) }
    end

    private

    def create_with_first_version
      @document.creator = @current_user

      doc_params = @document_params&.dig(:document_versions_attributes, '0')
      raise ActorError, 'Missing document version attributes' if doc_params.nil?

      @new_version = @document.document_versions.build(
        number: @document.next_version_number,
        title: doc_params['title'],
        description: doc_params['description'],
        document_version_file: doc_params['document_version_file'],
        # No create_embeddings here (doc/notizen_immer_indexiert_plan.md): the form
        # sends none, and an explicit nil overrode the column's default of true, so
        # every new document skipped indexing (review of #778, P1). The default is
        # the answer; the seam decides whether a job runs.
        create_summary: doc_params['create_summary'],
        organisation: @document.organisation,
        user: @current_user
      )
      @document.current_version = @new_version
      @document.save!
    end
  end
end
