# frozen_string_literal: true

class ProjectPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      scope.where(id: AccessCheck::ProjectAccessService.accessible_projects(user, organisation).select(:id))
    end
  end

  def index?
    return false unless user.active_organisations.exists?

    user.active_organisations.any? do |org|
      user.account_admin_in?(org) ||
        has_global_read_permission_in?(org) ||
        has_any_project_with_read_access_in?(org)
    end
  end

  def show?
    return false unless active_member_of_record_organisation?
    return account_admin? if record.archived?
    return true if account_admin?

    has_any_area_read_access? || has_global_read_permission?
  end

  def create?
    return false unless user.active_organisations.exists?

    user.active_organisations.any? do |org|
      user.account_admin_in?(org) ||
        user.has_permission_in_organisation?(org, 'projects', 'create_new_projects')
    end
  end

  def update?
    return false unless active_member_of_record_organisation?
    return true if account_admin?

    can_change_project_properties?
  end

  def archive?
    return false unless active_member_of_record_organisation?
    return false if record.archived?
    return true if account_admin?

    can_change_project_properties?
  end

  def unarchive?
    return false unless record&.archived?
    return false unless active_member_of_record_organisation?

    account_admin?
  end

  def destroy?
    return false unless active_member_of_record_organisation?
    return false unless record.archived?

    account_admin?
  end

  def area_access?(area, action)
    return false unless active_member_of_record_organisation?
    return true if account_admin?
    return archived_area_access?(area, action) if record.archived?

    if area.to_sym == :time_sessions
      time_permission = user.time_session_permissions.backed_by_project_access.find_by(project: record)
      if time_permission.present?
        case action.to_sym
        when :write then return time_permission.can_create_own
        when :read then return time_permission.can_view_own || time_permission.can_view_all
        end
      end
    end

    AccessCheck::ProjectAccessService.new(user, record).can?(action, area)
  end

  # Changing many tickets of this project at once (doc/ticket_bulk_edit_plan.md):
  # the same right as writing one ticket, asked of the project because a bulk
  # request names no single ticket.
  def bulk_edit_tickets?
    area_access?(:tickets, :write)
  end

  # Moving or deleting many tickets of this project at once (slice 7): the
  # same rights TicketPolicy#move? and #destroy? ask per ticket, asked of the
  # project because a bulk request names no single ticket.
  def bulk_move_tickets?
    active_member_of_record_organisation? && (account_admin? || has_permission?('tickets', 'move_tickets'))
  end

  def bulk_delete_tickets?
    active_member_of_record_organisation? && (account_admin? || has_permission?('tickets', 'delete_tickets'))
  end

  def view_activities?
    return false unless active_member_of_record_organisation?
    return true if account_admin?

    has_any_area_read_access?
  end

  private

  # An archived project is the admins' alone (AccessCheck::ProjectAccessService),
  # with one exception: members keep READING their own booked hours there, so a
  # monthly total does not shrink when an admin archives a project.
  # TimeSessions::ViewingScope narrows what they read to their own bookings.
  def archived_area_access?(area, action)
    return false unless area.to_sym == :time_sessions && action.to_sym == :read

    TimeSessions::ViewingScope.call(user: user, project: record).tier != :none
  end

  def active_member_of_record_organisation?
    record&.organisation && user.active_member_of_organisation?(record.organisation)
  end

  # Checks whether the user has at least one area with read/write rights in the project
  def has_any_area_read_access?
    permission = ProjectPermission.find_by(user: user, project: record)
    return false unless permission

    ProjectPermission.access_areas.any? do |area|
      %w[read_only read_write].include?(permission.public_send("#{area}_access"))
    end
  end

  # Checks global read permissions for at least one project area (current tenant)
  def has_global_read_permission?
    global_read_actions.any? { |action| has_permission?('projects', action) }
  end

  # Checks global read permissions in a specific organisation
  def has_global_read_permission_in?(org)
    global_read_actions.any? { |action| user.has_permission_in_organisation?(org, 'projects', action) }
  end

  def global_read_actions
    @global_read_actions ||= Permission::CATEGORIES[:projects].select do |action|
      action.start_with?('read_access_') && action.end_with?('_all_projects')
    end
  end

  # Checks whether the user is assigned to the project AND has the change_project_properties permission
  def can_change_project_properties?
    ProjectPermission.exists?(user: user, project: record) &&
      has_permission?('projects', 'change_project_properties')
  end

  # Checks whether the user has read rights in any project of the organisation
  def has_any_project_with_read_access_in?(org)
    ProjectPermission.joins(:project)
                     .where(user: user, projects: { organisation_id: org.id })
                     .where(
                       ProjectPermission.arel_table[:tickets_access].not_eq(0)
                         .or(ProjectPermission.arel_table[:notes_access].not_eq(0))
                         .or(ProjectPermission.arel_table[:chats_access].not_eq(0))
                         .or(ProjectPermission.arel_table[:documents_access].not_eq(0))
                         .or(ProjectPermission.arel_table[:documentation_access].not_eq(0))
                         .or(ProjectPermission.arel_table[:meetings_access].not_eq(0))
                     )
                     .exists?
  end
end
