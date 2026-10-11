# frozen_string_literal: true

# The thin door the time list and its menu entry go through: may this person
# open the list at all, which projects may they filter by, and in which
# projects may they book. The first two answers belong to
# TimeSessions::ViewingScope (one owner of the "all / own / none" rule); this
# class used to carry its own copy that knew neither the viewing flags nor
# deactivated memberships. The third is the booking flag, can_create_own.
class TimeSessionNavigationService
  attr_reader :user, :organisation

  def initialize(user, organisation)
    @user = user
    @organisation = organisation
  end

  # The "Zeiten" menu entry, and the list behind it.
  def can_show_all_time_sessions_menu?
    viewing_scope.sees_anything?
  end

  # The projects the list's filter offers: the ones in which this person sees
  # any time at all.
  def accessible_projects_with_time_sessions
    viewing_scope.projects.order(:name)
  end

  # The projects this person may book time in: every project for an account
  # admin, otherwise the ones with a persisted can_create_own row. Fail-closed
  # like the viewing rule: no membership or a deactivated one grants nothing.
  def bookable_projects
    return Project.none unless active_member?
    return Project.where(organisation_id: organisation.id).order(:name) if user.account_admin_in?(organisation)

    permitted = user.time_session_permissions
                    .backed_by_project_access
                    .joins(:project)
                    .where(projects: { organisation_id: organisation.id }, can_create_own: true)
                    .select(:project_id)
    Project.where(id: permitted).order(:name)
  end

  private

  def viewing_scope
    @viewing_scope ||= TimeSessions::ViewingScope.for_organisation(user: user, organisation: organisation)
  end

  def active_member?
    user.present? && organisation.present? && user.active_member_of_organisation?(organisation)
  end
end
