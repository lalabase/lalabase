# frozen_string_literal: true

# Provides access to the current user and other request-specific information.
# Used by background broadcasts (e.g. Chatpost#broadcast_created) to pull the
# request-local user/organisation so live-streamed UI matches the initial
# render's authorization context.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
  attribute :organisation
  attribute :project_policies
  attribute :area_access_anywhere_memo
  attribute :notification_source_projects_memo
  attribute :legal_identity

  # Request-scoped memo for ProjectPolicy. The dashboard render builds ~9-15 policies per page
  # (every widget's #should_render? plus available_widgets_for), each of which hits the DB. Reuse
  # one instance per (user, project) per request. CurrentAttributes resets this between requests
  # (and specs reset it after each example), so no instance leaks across authorization contexts.
  def project_policy(user, project)
    self.project_policies ||= {}
    project_policies[[user&.id, project&.id]] ||= ProjectPolicy.new(user, project)
  end

  # Request-scoped memo for Notification.source_projects_for, the project set behind every
  # unread count. The layout asks for that count three times per page (sidebar link, count
  # frame, mobile nav) and the inbox controller a fourth; for a member with local project rights
  # one resolution is nine queries. The relation is memoized, not its ids: the eight permission
  # reads run while it is built, and the count around it stays a fresh query, so a "mark all as
  # read" earlier in the same request still shows.
  def notification_source_projects(user, organisation, area = nil)
    self.notification_source_projects_memo ||= {}
    notification_source_projects_memo[[user&.id, organisation&.id, area]] ||= yield
  end

  # True when `user` has `area:action` in AT LEAST ONE active project of `organisation`.
  #
  # The organisation overview (briefings#show) aggregates across all of a viewer's projects, so a
  # widget's visibility is an "any project" question — distinct from the single-project ProjectPolicy
  # the project dashboard uses. This reuses the EXACT per-project #area_access? (no duplicated
  # permission logic) over the user's accessible projects, short-circuiting on the first match and
  # reusing the #project_policy memo. Admins short-circuit to true. Memoized per
  # (user, org, area, action) per request.
  #
  # Iterates accessible projects rather than running an area-specific SQL exists?: it keeps the
  # permission rules in one place (#area_access?) at the cost of N policy checks. Fine for typical
  # project counts (short-circuit + memo); revisit with an area-specific query if it ever gets hot.
  def area_access_anywhere?(user, organisation, area, action)
    return false unless user && organisation
    return true if user.account_admin_in?(organisation)

    self.area_access_anywhere_memo ||= {}
    key = [user.id, organisation.id, area.to_sym, action.to_sym]
    return area_access_anywhere_memo[key] if area_access_anywhere_memo.key?(key)

    accessible = ProjectPolicy::Scope.new(user, organisation.projects.active).resolve
    area_access_anywhere_memo[key] =
      accessible.any? { |project| project_policy(user, project).area_access?(area, action) }
  end
end
