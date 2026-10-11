# frozen_string_literal: true

# app/services/actors/save_note.rb

module Actors
  class SaveNote < BaseActor
    def initialize(project:, params:, current_user:, id: nil)
      super()
      @note = find_note(project, params, id)
      @note_params = params
      @current_user = current_user
    end

    def record
      @note
    end

    def perform
      raise ActorError, 'Note not found' if @note.nil?

      if @note.id.present?
        @note.update!(@note_params)
      else
        @note.creator = @current_user
        @note.save!
      end
    end

    def enqueue_jobs
      return unless @note&.create_embeddings?

      enqueue_after_commit do
        EmbeddingProcessingJob.perform_later(
          record_class: Note,
          record_id: @note.id,
          fragment_association: :fragments
        )
      end
    end

    private

    # Tenant-scoped lookup. A given id that matches no note in this tenant
    # (including a foreign-tenant id) yields nil, which #perform turns into a
    # "Note not found" failure. A blank id builds a new note in the project.
    def find_note(project, params, id)
      if id.present?
        Note.where(organisation: project.organisation, id: id).first
      else
        project.notes.build(params)
      end
    end
  end
end
