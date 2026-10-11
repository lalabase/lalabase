# frozen_string_literal: true

class SummaryProcessingJob < ApplicationJob
  queue_as :default

  LOG_TAG = 'SummaryProcessingJob'

  discard_on ActiveJob::DeserializationError do |_job, error|
    Rails.logger.warn "#{LOG_TAG}: Record not found - #{error.message}"
  end

  def perform(record_class:, record_id:)
    # Tenanted records (DocumentVersion) require a current tenant to load
    # (require_tenant = true). A job runs with no ambient tenant, so load without
    # one, then run the service inside the record's own organisation — same
    # pattern as EmbeddingProcessingJob (embedding_processing_job.rb:11-13).
    # Do NOT route Meeting through this job: meetings have their own
    # Meetings::SummaryJob, and the shared column names carry INVERTED flag
    # semantics (here "summary present", on Meeting "generation pending") — the
    # generic service would also read the concatenated plain_text_version and
    # violate the transcript-first source rule (review #235).
    record = ActsAsTenant.without_tenant { record_class.find(record_id) }

    ActsAsTenant.with_tenant(record.organisation) do
      SummaryProcessingService.new(record).process
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn "#{LOG_TAG}: #{record_class.name} with ID #{record_id} not found - #{e.message}"
  rescue StandardError => e
    Rails.logger.error "#{LOG_TAG}: Error processing #{record_class.name} with ID #{record_id} - #{e.message}"
    raise
  end
end
