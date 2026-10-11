# frozen_string_literal: true

# Controller-level policy for notification bulk operations
#
# PURPOSE:
# Handles authorization for collection-level and controller-level operations
# like mark_all_read, archive_all, preferences, etc.
#
# WHY SEPARATED:
# - Individual notification authorization -> NotificationPolicy
# - Controller/bulk operations -> NotificationsPolicy (plural)
# - Follows the established pattern of PowerSearchPolicy
#
# USAGE:
# authorize :notifications, :mark_all_read?
# authorize :notifications, :preferences?

class NotificationsPolicy < Struct.new(:user, :notifications)
  def initialize(user, notifications)
    raise Pundit::NotAuthorizedError, 'must be logged in' unless user

    super
  end

  # Bulk: Mark all your own notifications as read
  def mark_all_read?
    true
  end

  # Bulk: Archive all read notifications
  def archive_all?
    true
  end

  # Show notification settings
  def preferences?
    true
  end

  # Change notification settings
  def update_preferences?
    true
  end

  # Show and manage ticket exceptions
  def ticket_exceptions?
    true
  end

  def remove_ticket_exception?
    true
  end

  # Show notification statistics
  def stats?
    true
  end
end
