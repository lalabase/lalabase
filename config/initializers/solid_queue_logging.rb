# frozen_string_literal: true

# Reduce SolidQueue log verbosity in development
if Rails.env.development?
  # Silence SolidQueue's internal logging
  Rails.application.config.after_initialize do
    # Silence ActiveRecord SQL logs for SolidQueue
    ActiveRecord::Base.logger.level = Logger::WARN if defined?(ActiveRecord::Base) && ActiveRecord::Base.logger

    if defined?(SolidQueue)
      # Create a null logger to silence SolidQueue logs
      null_logger = Logger.new(File::NULL)
      null_logger.level = Logger::ERROR

      # Override SolidQueue's logger
      begin
        SolidQueue.configure do |config|
          config.logger = null_logger
        end
      rescue StandardError => e
        Rails.logger.debug "Could not configure SolidQueue logger: #{e.message}"
      end

      # Also silence the individual process loggers if they exist
      [
        SolidQueue::Worker,
        SolidQueue::Dispatcher,
        SolidQueue::Supervisor
      ].each do |klass|
        klass.logger = null_logger if klass.respond_to?(:logger=)
      rescue StandardError => e
        Rails.logger.debug "Could not set logger for #{klass}: #{e.message}"
      end
    end
  end
end
