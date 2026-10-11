# frozen_string_literal: true

# Splits a user's projects into "active" (recently accessed, unread notifications,
# current project) and "rest" for sidebar display.
#
# Only splits when the user has more than MAX_UNGROUPED projects.
# Ensures at least MIN_ACTIVE projects in the active group.
#
# Usage:
#   groups = SidebarProjectGroupingService.new(user, organisation,
#     projects: cached_user_projects,
#     current_project: current_project
#   ).call
#   # => { active: [...], rest: [...] }
class SidebarProjectGroupingService
  MAX_UNGROUPED = 5
  MIN_ACTIVE    = 3
  RECENCY_CUTOFF_DAYS = 60

  attr_reader :user, :organisation, :projects, :current_project

  # @param user [User]
  # @param organisation [Organisation]
  # @param projects [Array<Project>] pre-filtered list of accessible projects (all orgs)
  # @param current_project [Project, nil]
  def initialize(user, organisation, projects:, current_project: nil)
    @user = user
    @organisation = organisation
    @projects = projects
    @current_project = current_project
  end

  # @return [Hash{Symbol => Array<Project>}] :pinned, :active and :rest
  def call
    org_projects = projects.select { |p| p.organisation_id == organisation.id && !p.archived? }

    pinned, unpinned = extract_pinned(org_projects)

    # Once projects are pinned, all the others recede behind the
    # "more projects" toggle (only visible on click) — except
    # the currently opened project, which always stays visible.
    if pinned.any?
      active, rest = unpinned.partition { |p| p.id == current_project&.id }
      return { pinned: pinned, active: active, rest: rest }
    end

    return { pinned: pinned, active: unpinned, rest: [] } if unpinned.size <= MAX_UNGROUPED

    access_map = build_access_map(unpinned)
    unread_ids = unread_project_ids(unpinned)
    cutoff = RECENCY_CUTOFF_DAYS.days.ago

    active, rest = unpinned.partition do |p|
      access_map[p.id]&.>(cutoff) ||
        p.id == current_project&.id ||
        unread_ids.include?(p.id)
    end

    backfill_active!(active, rest, access_map)

    { pinned: pinned, active: active, rest: rest }
  end

  private

  # Splits org_projects into [pinned (in pin order), unpinned].
  def extract_pinned(org_projects)
    pinned_ids = user.sidebar_pins.pins_for(organisation)['projects']
    return [[], org_projects] if pinned_ids.empty?

    by_id = org_projects.index_by { |p| p.id.to_s }
    pinned = pinned_ids.filter_map { |id| by_id[id] }
    pinned_set = pinned.map(&:id).to_set
    unpinned = org_projects.reject { |p| pinned_set.include?(p.id) }

    [pinned, unpinned]
  end

  def build_access_map(org_projects)
    project_ids = org_projects.map(&:id)

    user.project_permissions
        .where(project_id: project_ids)
        .where.not(last_accessed_at: nil)
        .pluck(:project_id, :last_accessed_at)
        .to_h
  end

  def unread_project_ids(org_projects)
    project_ids = org_projects.map(&:id)

    # The inbox rule (areas, active projects): no dot for a project whose unread
    # rows the person may not see.
    Notification.inbox_unread(user, organisation)
                .where(project_id: project_ids)
                .distinct.pluck(:project_id)
                .to_set
  end

  # Ensure at least MIN_ACTIVE projects in the active group by pulling
  # the most recently accessed from rest.
  def backfill_active!(active, rest, access_map)
    return if active.size >= MIN_ACTIVE

    fill_count = MIN_ACTIVE - active.size
    rest.sort_by! { |p| access_map[p.id] || Time.at(0) }.reverse!
    active.concat(rest.shift(fill_count))
  end
end
