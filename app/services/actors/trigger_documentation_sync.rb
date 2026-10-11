# frozen_string_literal: true

module Actors
  # Kick off a manual re-sync of a DocumentationSet: mark it syncing for
  # immediate UI feedback, then enqueue the job after commit. The job owns the
  # syncing → ready/failed transitions from there.
  class TriggerDocumentationSync < BaseActor
    def initialize(documentation_set:, current_user:, trigger: 'manual')
      super()
      @documentation_set = documentation_set
      @current_user = current_user
      @trigger = trigger
    end

    def record
      @documentation_set
    end

    def perform
      raise ActorError, 'Documentation set not found' if @documentation_set.nil?

      @documentation_set.update!(sync_status: 'syncing')
    end

    def enqueue_jobs
      set_id = @documentation_set.id
      trigger = @trigger
      user_id = @current_user&.id

      enqueue_after_commit do
        DocumentationSyncJob.perform_later(set_id, trigger: trigger, triggered_by_user_id: user_id)
      end
    end
  end
end
