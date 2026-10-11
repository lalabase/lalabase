# frozen_string_literal: true

class TimeSessionGroupPolicy < ApplicationPolicy
  def index?
    # In index? the record is the TimeSessionGroup class, not an instance
    # We check the permission via the current organisation
    organisation = ActsAsTenant.current_tenant
    return false unless organisation

    user.account_admin_in?(organisation) ||
      has_finance_role_for_organisation?(organisation)
  end

  def show?
    # Admin, Finance, or has TimeSessions in the group
    index? || has_time_sessions_in_group?
  end

  # The bookings a billing already holds, shown on demand in the assignment
  # panel. Exactly the permission to see the billing: it is the same data, in a
  # smaller frame, and giving it a rule of its own would be a second answer to
  # one question. The rows are policy_scoped on top of this, so seeing the
  # billing never means seeing everybody's hours in it.
  def entries?
    show?
  end

  def create?
    # In create? the record can be either an instance or the class
    if record.is_a?(Class)
      # If it is the class, we use the current organisation
      organisation = ActsAsTenant.current_tenant
      return false unless organisation

      user.account_admin_in?(organisation) ||
        has_finance_role_for_organisation?(organisation)
    else
      # If it is an instance
      user.account_admin_in?(record.organisation) ||
        has_finance_role?
    end
  end

  def update?
    # Admin, Finance, or the creator can edit
    create? || record.creator_id == user.id
  end

  def destroy?
    # Only admins can delete
    user.account_admin_in?(record.organisation)
  end

  def mark_as_billed?
    # Only admin or Finance can mark as paid
    create?
  end

  def generate_customer_descriptions?
    # Only admin, Finance, or the creator can generate customer descriptions
    update?
  end

  def export_customer_descriptions?
    # Anyone who can see the group can also export it
    show?
  end

  def chronological?
    # Same as show - anyone who can view the group can see chronological view
    show?
  end

  def aggregated?
    # Same as show - anyone who can view the group can see aggregated view
    show?
  end

  def customer_export?
    # Same as show - anyone who can view the group can see customer export view
    show?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      organisation = ActsAsTenant.current_tenant
      return scope.none unless organisation

      if user.account_admin_in?(organisation)
        # Admins see all groups
        scope.all
      elsif user.memberships.joins(:role).where(organisation: organisation, roles: { title: %w[Finance Buchhaltung finance buchhaltung] }).exists?
        # The Finance role sees all groups
        scope.all
      else
        # Other users only see groups with their TimeSessions
        # Either they created the TimeSession or have project access via TimeSessionPermissions
        group_ids_from_own_sessions = scope.joins(:time_sessions)
                                           .where(time_sessions: { creator_id: user.id })
                                           .pluck(:id)

        # Use the new TimeSessionPermission system
        viewable_project_ids = user.time_session_permissions.backed_by_project_access
                                   .where(can_view_all: true).select(:project_id)
        group_ids_from_project_access = scope.joins(:time_sessions)
                                             .where(time_sessions: { project_id: viewable_project_ids })
                                             .pluck(:id)

        all_group_ids = (group_ids_from_own_sessions + group_ids_from_project_access).uniq
        scope.where(id: all_group_ids)
      end
    end
  end

  private

  def has_finance_role_in_scope?(organisation)
    user.memberships
        .joins(:role)
        .where(organisation: organisation, roles: { title: %w[Finance Buchhaltung finance buchhaltung] })
        .exists?
  end

  def has_finance_role?
    # Checks whether the user has a Finance/Buchhaltung role
    user.memberships
        .joins(:role)
        .where(organisation: record.organisation, roles: { title: %w[Finance Buchhaltung finance buchhaltung] })
        .exists?
  end

  def has_finance_role_for_organisation?(organisation)
    # Checks whether the user has a Finance/Buchhaltung role in a specific organisation
    user.memberships
        .joins(:role)
        .where(organisation: organisation, roles: { title: %w[Finance Buchhaltung finance buchhaltung] })
        .exists?
  end

  def has_time_sessions_in_group?
    # Checks whether the user has TimeSessions in this group (own or project access)
    own_sessions = record.time_sessions.where(creator_id: user.id).exists?

    # Use the new TimeSessionPermission system:
    # Check whether the user has TimeSession permissions for projects in this group
    project_ids_in_group = record.time_sessions.distinct.pluck(:project_id)

    project_access = user.time_session_permissions
                         .backed_by_project_access
                         .where(project_id: project_ids_in_group)
                         .where(can_view_all: true)
                         .exists?

    own_sessions || project_access
  end
end
