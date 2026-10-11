# frozen_string_literal: true

module Meetings
  # Generates the AI summary for a meeting off the request path. Tenant-safe from
  # birth (the Task 0 pattern): Solid Queue dequeues jobs with NO ambient tenant,
  # so load the meeting without one, then run the service inside its organisation
  # so acts_as_tenant scoping holds (require_tenant = true). Mirrors
  # EmbeddingProcessingJob (embedding_processing_job.rb:11-13).
  class SummaryJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound do |_job, error|
      Rails.logger.warn("Meetings::SummaryJob discarded: #{error.message}")
    end

    def perform(meeting_id:)
      meeting = ActsAsTenant.without_tenant { Meeting.find(meeting_id) }

      ActsAsTenant.with_tenant(meeting.organisation) do
        Meetings::SummaryService.call(meeting: meeting)
      end
    end
  end
end
