# frozen_string_literal: true

class TimeSessionPolicy < ApplicationPolicy
  class Scope < Scope
    # The org-wide door to the visibility rule. The rule itself lives in
    # TimeSessions::ViewingScope, which is also what every report over booked
    # time asks, so a user cannot see one set of hours in the list and another
    # in the chat answer beside it.
    #
    # The organisation comes from the tenant (ApplicationPolicy::Scope sets it
    # from ActsAsTenant.current_tenant). It used to be read off `scope.first`,
    # which loaded a time session on every dashboard tile, briefing and list
    # before the scope could decide anything.
    def resolve
      return scope.none unless organisation

      TimeSessions::ViewingScope.for_organisation(user: user, organisation: organisation).apply(scope)
    end
  end

  def index?
    # Check whether the user has at least one project with TimeSession rights
    if record.is_a?(Class)
      # The list itself. One owner with the menu entry
      # (TimeSessionNavigationService): admin, or a viewing flag somewhere. A
      # row that grants no viewing flag used to open the list (mere existence).
      TimeSessions::ViewingScope.for_organisation(user: user, organisation: organisation).sees_anything?
    elsif record.project
      return true if account_admin?

      time_permission = get_time_permission
      time_permission.present?
    else
      true
    end
  end

  def show?
    return true if account_admin?

    time_permission = get_time_permission

    # Own sessions
    if record.creator_id == user.id
      # Check whether the user may see their own
      return time_permission&.can_view_own? || false
    end

    # Other sessions; an archived project keeps members at their own
    return false if archived_project?

    time_permission&.can_view_all? || false
  end

  def create?
    return false unless record.project
    return true if account_admin?
    return false if archived_project?

    time_permission = get_time_permission
    time_permission&.can_create_own? || false
  end

  def update?
    # Billed sessions cannot be edited
    return false if record.billed?

    return true if account_admin?
    return false if archived_project?

    time_permission = get_time_permission

    if record.creator_id == user.id
      time_permission&.can_edit_own? || false
    else
      time_permission&.can_edit_all? || false
    end
  end

  def destroy?
    # Billed sessions cannot be deleted
    return false if record.billed?

    # Account admins can always delete
    return true if account_admin?
    return false if archived_project?

    time_permission = get_time_permission

    if record.creator_id == user.id
      time_permission&.can_delete_own? || false
    else
      time_permission&.can_delete_all? || false
    end
  end

  private

  # An archived project is read-only for members, and only their own hours
  # (AccessCheck::ProjectAccessService, TimeSessions::ViewingScope).
  def archived_project?
    record.project&.archived? || false
  end

  def get_time_permission
    return nil unless record.project

    @time_permission ||= user.time_session_permissions.backed_by_project_access.find_by(project: record.project)
  end

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.project)
  end
end
