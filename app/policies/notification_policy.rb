# frozen_string_literal: true

# Policy for notification access and authorization
#
# PURPOSE:
# Controls who is allowed to see and edit which notifications.
# Notifications are highly personal - only the recipient may see them.
#
# WHY BUILT THIS WAY:
# - Simple rule: Only your own notifications are visible
# - Multi-tenancy: Notifications must belong to the current organisation
# - Standard Pundit pattern for consistent authorization
# - Scope for performant DB queries
#
# EXAMPLE:
# A user can see, read and archive their own notifications
# A user can NOT see other users' notifications

class NotificationPolicy < ApplicationPolicy
  # Show only your own notifications
  def index?
    true # Users can always show their own notifications
  end

  # Show a single notification
  def show?
    authorized?
  end

  # Update a notification (mark as read, archive, etc.)
  def update?
    authorized?
  end

  # Archive a notification
  def destroy?
    authorized?
  end

  # Mark a single notification as read
  def mark_read?
    authorized?
  end

  # Mark a single notification as unread
  def mark_unread?
    authorized?
  end

  # Archive a single notification
  def archive?
    authorized?
  end

  def open?
    show?
  end

  # Mark grouped notifications as read
  def mark_group_read?
    authorized?
  end

  # Show the activities of a grouped notification
  def activities?
    authorized?
  end

  # Scope for notification queries
  class Scope < Scope
    def resolve
      # Only notifications for the current user in the current organisation, and only
      # from projects they can still reach.
      #
      # The access filter sits HERE rather than at each call site because it had already
      # been forgotten once: the unread badge counted with it (User#unread_notifications_count)
      # while the inbox list underneath rendered without it, so the number and the list
      # disagreed for anyone who had lost a project.
      #
      # accessible_for keeps notifications with no project (system messages) and drops the
      # rest by CURRENT access, so nothing has to be deleted or restored when someone
      # leaves a project and comes back.
      scope.where(
        recipient: user,
        organisation: organisation
      ).accessible_for(user, organisation)
    end
  end

  private

  # Central authorization check: the recipient, in the correct organisation, and only
  # while they can still reach the project the notification came from.
  #
  # The project half has to be here as well as in Scope. Without it the two doors
  # disagree: the inbox would hide a notification from a project the person was taken
  # off, while a kept deep link would still let them open, mark and archive it. One rule,
  # two entrances, and the record entrance is the one that needs no listing to find.
  def authorized?
    owner? && same_organisation? && still_reaches_project?
  end

  # Asked through Notification.accessible_for so this is the same rule the inbox, the
  # unread badge and EmailDeliveryJob ask, not a fourth copy of it. A notification with
  # no project (system message) belongs to no project rights and always passes.
  def still_reaches_project?
    Notification.where(id: record.id).accessible_for(user, organisation).exists?
  end

  # Checks whether the user is the recipient of the notification
  def owner?
    record.recipient == user
  end

  # Checks whether the notification belongs to the current organisation
  def same_organisation?
    record.organisation == organisation
  end
end
