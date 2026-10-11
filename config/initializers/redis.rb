# frozen_string_literal: true

require 'redis'

# Configure Redis instance - use environment variable for connection
redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')

# Only connect during server/console, not during asset precompilation
REDIS = if defined?(Rails::Server) || defined?(Rails::Console)
          Redis.new(url: redis_url)
        else
          begin
            Redis.new(url: redis_url, timeout: 1)
          rescue StandardError
            nil
          end
        end
