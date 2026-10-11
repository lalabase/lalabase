# frozen_string_literal: true

module Meetings
  # Generates the AI analysis for a MeetingAnalysis off the request path. Tenant-safe
  # from birth (the Task 0 pattern): Solid Queue dequeues with NO ambient tenant, so
  # load the analysis without one, then run the service inside its organisation.
  # Mirrors Meetings::SummaryJob.
  class AnalysisJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound do |_job, error|
      Rails.logger.warn("Meetings::AnalysisJob discarded: #{error.message}")
    end

    def perform(analysis_id:)
      analysis = ActsAsTenant.without_tenant { MeetingAnalysis.find(analysis_id) }

      ActsAsTenant.with_tenant(analysis.organisation) do
        Meetings::AnalysisService.call(analysis: analysis)
      end
    end
  end
end
