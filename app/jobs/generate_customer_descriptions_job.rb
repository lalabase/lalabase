# frozen_string_literal: true

# Background job for generating customer descriptions for TimeSessions
# in a TimeSessionGroup. Recommended for groups with >10 sessions.
#
#   GenerateCustomerDescriptionsJob.perform_later(
#     time_session_group_id: group_id,
#     regenerate: false,
#     user_id: current_user.id  # optional, for logging context
#   )
class GenerateCustomerDescriptionsJob < ApplicationJob
  queue_as :default

  retry_on Faraday::TimeoutError, wait: 30.seconds, attempts: 3
  retry_on Faraday::ConnectionFailed, wait: 1.minute, attempts: 2

  discard_on ActiveRecord::RecordNotFound do |_job, error|
    Rails.logger.error("GenerateCustomerDescriptionsJob discarded: #{error.message}")
  end

  # Solid Queue deserialises job arguments slightly differently depending on
  # whether they were enqueued as positional or keyword arguments. Supporting
  # both keeps the job backwards compatible while we transition.
  def perform(*raw_args, **raw_kwargs)
    args = normalize_arguments(raw_args, raw_kwargs)

    @job_started_at = Time.current
    @group = TimeSessionGroup.find(args.fetch(:time_session_group_id))
    @user = args[:user_id].present? ? User.find(args[:user_id]) : nil
    @regenerate = args.fetch(:regenerate, false)

    log_start

    generator = BulkCustomerDescriptionGenerator.new(@group, regenerate: @regenerate)
    @results = generator.generate_all

    log_completion

    @results
  rescue StandardError => e
    log_error(e)
    raise
  end

  private

  def normalize_arguments(raw_args, raw_kwargs)
    normalized = raw_kwargs.present? ? raw_kwargs.deep_symbolize_keys : {}

    case raw_args.length
    when 0
      # nothing to merge
    when 1
      first_arg = raw_args.first

      if first_arg.respond_to?(:deep_symbolize_keys)
        normalized.merge!(first_arg.deep_symbolize_keys)
      else
        normalized[:time_session_group_id] ||= first_arg
      end
    when 2
      identifier, options = raw_args

      normalized[:time_session_group_id] ||= identifier unless identifier.respond_to?(:deep_symbolize_keys)

      raise ArgumentError, "Unsupported options type: #{options.class}" unless options.respond_to?(:deep_symbolize_keys)

      normalized.merge!(options.deep_symbolize_keys)

    else
      raise ArgumentError, "Unable to normalize job arguments: #{raw_args.inspect} #{raw_kwargs.inspect}"
    end

    raise ArgumentError, 'time_session_group_id is missing' unless normalized.key?(:time_session_group_id)

    normalized
  end

  def log_start
    Rails.logger.info(
      'GenerateCustomerDescriptionsJob started: ' \
      "group=#{@group.id} name=#{@group.name.inspect} " \
      "regenerate=#{@regenerate} user=#{@user&.id}"
    )
  end

  def log_completion
    duration = (Time.current - @job_started_at).round(2)
    Rails.logger.info(
      'GenerateCustomerDescriptionsJob completed: ' \
      "group=#{@group.id} results=#{@results.inspect} duration=#{duration}s"
    )
  end

  def log_error(error)
    Rails.logger.error(
      'GenerateCustomerDescriptionsJob failed: ' \
      "group=#{@group&.id} error=#{error.class}:#{error.message}"
    )
  end
end
