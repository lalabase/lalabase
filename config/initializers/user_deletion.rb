# frozen_string_literal: true

# =============================================================================
# User Deletion Configuration
# =============================================================================
# Configures grace periods and settings for user account deletion functionality.
#
# Email Grace Period:
# After a user account is soft-deleted, their email remains reserved for the
# configured grace period to prevent immediate reuse and ensure data integrity.
# =============================================================================

Rails.application.configure do
  # Default grace period for email reusability after account deletion
  # During this period, the deleted user's email cannot be used for new registrations
  config.default_email_grace_period = 48.hours

  # Maximum reason length for deletion requests
  config.max_deletion_reason_length = 500

  # Whether to send notification emails when accounts are deleted
  config.send_deletion_notifications = true
end
