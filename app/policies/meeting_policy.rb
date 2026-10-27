# frozen_string_literal: true

# Mirrors NotePolicy: area-scoped access to Meeting records via the shared
# ProjectPolicy#area_access?(:meetings, …) seam. The Scope filters collections
# to the projects the user may read in the :meetings area.
class MeetingPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      project_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :read, area: :meetings
      )
      scope.where(project_id: project_ids)
    end
  end

  def index?
    # For the index action the Meeting class is authorized, not an instance.
    # Read access is enforced by the controller's area authorization.
    true
  end

  def show?
    project_policy.area_access?(:meetings, :read)
  end

  def create?
    project_policy.area_access?(:meetings, :write)
  end

  # Pre-save LLM participant detection (Slice 5). Write-shaped and listed in
  # ProjectController#write_actions, so the area gate already blocks non-writers
  # before the action runs; this Pundit check is the second, defence-in-depth
  # guard (same double-gating as create_summary).
  def detect_participants?
    project_policy.area_access?(:meetings, :write)
  end

  def update?
    project_policy.area_access?(:meetings, :write)
  end

  # Linking a participant to the people directory (S2b): a meeting write, and
  # the directory itself (view_people), because the dialog lists it. The
  # controller authorizes with this, and the participant row asks the same to
  # show its link action, so the button and the server cannot disagree.
  def link_participants?
    update? && PersonPolicy.view_allowed?(user, organisation)
  end

  def destroy?
    account_admin? || project_policy.area_access?(:meetings, :write)
  end

  # Moving into another project (Actors::MoveMeeting): the role permission
  # move_meetings, like move_tickets, plus meetings write access here. The
  # target's write access is asked by the controller and the actor. An
  # archived project is closed for it, account admins included: the area
  # check lets them write there, a move out of the archive is not meant.
  def move?
    return false if record.project.archived?

    (account_admin? || has_permission?('meetings', 'move_meetings')) &&
      project_policy.area_access?(:meetings, :write)
  end

  private

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.project)
  end
end
