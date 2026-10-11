# frozen_string_literal: true

# ================================
# BULK CUSTOMER DESCRIPTION GENERATOR
# ================================
# This service generates customer descriptions for all TimeSessions
# within a TimeSessionGroup. It handles bulk operations efficiently
# and provides detailed result tracking.
#
# Key Features:
# - Batch processing of all sessions in a group
# - Optional regeneration of existing descriptions
# - Detailed result tracking (success, failed, skipped)
# - Error handling per session (one failure doesn't stop the batch)
# - Optional background job for large groups (>10 sessions)
# - Progress logging for monitoring
#
# Usage:
#   # Process all sessions without customer_description
#   generator = BulkCustomerDescriptionGenerator.new(time_session_group)
#   results = generator.generate_all
#   # => { success: 10, failed: 1, skipped: 2 }
#
#   # Regenerate all descriptions
#   generator = BulkCustomerDescriptionGenerator.new(time_session_group, regenerate: true)
#   results = generator.generate_all
#
# For groups with > 10 sessions, consider using the background job:
#   GenerateCustomerDescriptionsJob.perform_later(group.id, regenerate: false)
# ================================

class BulkCustomerDescriptionGenerator
  # Threshold for triggering background job recommendation
  BACKGROUND_JOB_THRESHOLD = 10

  attr_reader :group, :regenerate

  def initialize(time_session_group, regenerate: false)
    @group = time_session_group
    @regenerate = regenerate
    @results = { success: 0, failed: 0, skipped: 0, errors: [] }
  end

  # Generate customer descriptions for all applicable time sessions
  #
  # @return [Hash] Results hash with counts and errors
  #   {
  #     success: Integer,  # Successfully generated descriptions
  #     failed: Integer,   # Failed generations
  #     skipped: Integer,  # Sessions skipped (already have description)
  #     errors: Array      # Array of error messages for failed sessions
  #   }
  def generate_all
    # Feature gate — twin of Actors::GenerateGroupCustomerDescriptions#
    # guard_feature_available! (R3), for the same reason the billed twin below
    # exists: this generator is reachable through the ASYNC job path, and between
    # enqueue and execution the org can switch its chat provider or lose its
    # credential (and a retry_on replays a job that was legal when queued). Without
    # this, an org that moved to Mistral would still have its time entries sent to
    # OpenAI by a job it queued yesterday.
    #
    # ONE question where the opt-in and the pin used to be two hand-written halves:
    # the batch is refused up-front with ONE localized sentence naming the actual
    # reason, instead of looping every session into N raw English exception messages
    # (the per-session rescue would surface them all in the flash).
    availability = group.organisation&.ai_available_for?(:customer_description)
    unless availability&.available?
      @results[:errors] << Lalabase::Llm::FeatureRegistry.unavailable_hint(availability, group.organisation)
      return @results
    end

    # Billed guard — deliberate defense-in-depth twin of the primary, coded
    # refuse in Actors::GenerateGroupCustomerDescriptions (plan §5-E3): protects
    # the ASYNC job path, where a job enqueued before the group was invoiced
    # (race, retry_on replay) would burn LLM budget on guaranteed
    # prevent_changes_when_billed failures. Same early-return shape as the
    # GDPR gate above; unify when a third batch-refuse appears.
    if group.billed?
      @results[:errors] << I18n.t('services.actors.generate_group_customer_descriptions.group_billed')
      return @results
    end

    log_start
    sessions = select_time_sessions

    # Hint warning without context detection: the former background_job_running?
    # check inspected the Sidekiq thread state and was always false under Solid Queue —
    # so the warning fired even INSIDE the background job. There is no reliable
    # "already running in a job" detection with ActiveJob; the
    # warning remains as a heuristic for the synchronous controller path.
    session_count = sessions.count
    Rails.logger.warn("Processing #{session_count} sessions synchronously. Consider using background job.") if session_count > BACKGROUND_JOB_THRESHOLD

    sessions.find_each do |time_session|
      process_session(time_session)
    end

    log_completion
    @results
  end

  # Check if processing should be done in background
  #
  # @return [Boolean] true if session count exceeds threshold
  def should_use_background_job?
    select_time_sessions.count > BACKGROUND_JOB_THRESHOLD
  end

  private

  # Select time sessions to process based on regenerate flag
  #
  # @return [ActiveRecord::Relation] Time sessions to process
  def select_time_sessions
    sessions = @group.time_sessions.includes(:ticket)

    if @regenerate
      # Process all sessions
      sessions
    else
      # Only process sessions without customer_description
      sessions.where(customer_description: nil)
    end
  end

  # Process a single time session
  #
  # @param time_session [TimeSession] The session to process
  def process_session(time_session)
    # Skip if session already has description and not regenerating
    if !@regenerate && time_session.customer_description.present?
      @results[:skipped] += 1
      log_skipped(time_session)
      return
    end

    # Generate description
    begin
      description = generate_description_for_session(time_session)

      # F1 fix (plan §5-E6): CustomerDescriptionGenerator rescues every provider
      # failure to nil. Writing that nil used to count as SUCCESS — a total
      # provider outage reported "N erfolgreich" (silent fail, §9.4). A blank
      # result is a failure; the session's existing description stays untouched.
      if description.blank?
        @results[:failed] += 1
        @results[:errors] << I18n.t('services.bulk_customer_description_generator.empty_result',
                                    id: time_session.id)
        log_failure(time_session, StandardError.new('LLM returned a blank description'))
        return
      end

      time_session.update!(customer_description: description)
      @results[:success] += 1
      log_success(time_session)
    rescue StandardError => e
      @results[:failed] += 1
      error_message = "TimeSession #{time_session.id}: #{e.message}"
      @results[:errors] << error_message
      log_failure(time_session, e)
    end
  end

  # Generate description for a single session using CustomerDescriptionGenerator
  #
  # @param time_session [TimeSession] The session to process
  # @return [String] Generated description
  def generate_description_for_session(time_session)
    generator = CustomerDescriptionGenerator.new(time_session)
    generator.generate
  end

  # Logging methods

  def log_start
    payload = {
      time_session_group_id: @group.id,
      group_name: @group.name,
      total_sessions: select_time_sessions.count,
      regenerate: @regenerate
    }

    Rails.logger.debug("BulkCustomerDescriptionGenerator started: #{payload}")
  end

  def log_completion
    payload = {
      time_session_group_id: @group.id,
      group_name: @group.name,
      results: @results
    }

    Rails.logger.debug("BulkCustomerDescriptionGenerator completed: #{payload}")
  end

  def log_success(time_session)
    # Intentionally empty - debug logging removed
  end

  def log_skipped(time_session)
    # Intentionally empty - debug logging removed
  end

  def log_failure(time_session, error)
    payload = {
      time_session_id: time_session.id,
      error_class: error.class.name,
      error_message: error.message,
      backtrace: error.backtrace&.first(3)
    }

    Rails.logger.error("Customer description generation failed: #{payload}")
  end
end
