# frozen_string_literal: true

# Mission Control Jobs Configuration
# Job queue monitoring interface for Solid Queue

# Disable HTTP Basic Authentication using multiple methods
ENV['MISSION_CONTROL_JOBS_HTTP_AUTH_ENABLED'] = 'false'

# Use our custom bridge controller for admin authentication
# Wrapped in to_prepare to ensure proper class loading
Rails.application.config.to_prepare do
  MissionControl::Jobs.base_controller_class = 'Admin::MissionControlController'

  # Explicitly disable HTTP Basic Authentication
  MissionControl::Jobs.http_basic_auth_enabled = false
  MissionControl::Jobs.http_basic_auth_user = nil
  MissionControl::Jobs.http_basic_auth_password = nil
end
