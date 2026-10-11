# frozen_string_literal: true

# Org-wide access matrix: rows = active org members, columns = active projects, cell =
# the member's *effective, condensed* access to that project plus its provenance.
#
# It does NOT reimplement the precedence engine — it aggregates the existing
# AccessCheck::ProjectMemberAccessResolver over every active project, reusing ONE resolver
# per project against the SAME preloaded user objects so the resolver's per-role memo and
# `memberships.loaded?` fast paths stay query-free across all columns.
#
# Query budget: ~c + 3·P (each resolver: project_permissions incl. users = 2, time-session
# permissions = 1), INDEPENDENT of the number of users U. Regression-guarded by the N+1
# guard in spec/services/access_check/org_access_matrix_spec.rb.
#
# Effective-access honesty (plan decision B): the resolver's :direct cells carry the RAW
# explicit grant. The matrix lifts them to the true effective level via
# ProjectPermission#effective_level (explicit no_access blocks; otherwise max(explicit,
# role)). This is deliberately audit-honest and may differ from the (config-oriented) Team
# page, which keeps showing the raw explicit level.
module AccessCheck
  class OrgAccessMatrix
    AREAS = ProjectPermission.access_areas

    # Condensed per-(user, project) access.
    #   level    -> highest effective level across the 6 areas
    #   source   -> :admin | :direct | :role | :none  (from the resolver)
    #   blocked  -> explicit grant present but every area effectively no_access
    #               (a deliberate lock-out that overrides role rights)
    #   per_area -> the 6 effective single levels, keyed by area
    SummaryCell = Struct.new(:level, :source, :blocked, :per_area, keyword_init: true) do
      def blocked?    = blocked
      def none?       = source == :none
      def access?     = source != :none && !blocked
      def inherited?  = %i[admin role].include?(source)
    end

    def initialize(organisation:, current_user:, member_scope: nil)
      @organisation = organisation
      @current_user = current_user
      # Optional Membership relation (e.g. the controller's policy_scope) that further
      # narrows the rows. Defaults to "all active org members" so the service is usable and
      # unit-testable without a Pundit context.
      @member_scope = member_scope
      @role_levels_cache = {}
    end

    # Ordered row set: active members only. "Active" means an active membership AND an active,
    # non-soft-deleted user (an active membership alone is not enough — Codex C3).
    def users
      @users ||= load_users
    end

    # Ordered column set: the org's active (non-archived) projects.
    def projects
      @projects ||= @organisation.projects.active
                                 .includes(:organisation)
                                 .order(Arel.sql('LOWER(projects.name)'))
                                 .to_a
    end

    def cell(user, project)
      grid.dig(project.id, user.id)
    end

    private

    # project_id => { user_id => SummaryCell }
    def grid
      @grid ||= build_grid
    end

    def build_grid
      projects.each_with_object({}) do |project, result|
        resolver = AccessCheck::ProjectMemberAccessResolver.new(project: project, current_user: @current_user)
        # Pass the SAME user objects every time so the resolver's role memo + loaded?-branch
        # stay query-free column after column.
        by_user = resolver.resolve(users).each_with_object({}) do |member, acc|
          acc[member.user.id] = summarise(member)
        end
        result[project.id] = by_user
      end
    end

    def summarise(member)
      per_area = effective_per_area(member)
      SummaryCell.new(
        level: highest(per_area.values),
        source: member.source,
        blocked: member.source == :direct && per_area.values.all? { |level| level == 'no_access' },
        per_area: per_area
      )
    end

    # Effective level per area. admin/role/none already carry their effective level in the
    # resolver cells; only :direct needs lifting from the raw explicit grant (decision B).
    def effective_per_area(member)
      return raw_levels(member) unless member.source == :direct

      role_levels = role_levels_for(member.user)
      AREAS.index_with { |area| member.permission.effective_level(area, role_levels[area]) }
    end

    def raw_levels(member)
      AREAS.index_with { |area| member.cells[area].level }
    end

    # Per-role global levels, memoised by role_id across ALL projects (role "*_all_projects"
    # rights are project-independent). Query-free thanks to the users' preload.
    def role_levels_for(user)
      role = user.role_in_organisation(@organisation)
      key = role&.id || :none
      @role_levels_cache[key] ||= AREAS.index_with do |area|
        AccessCheck::RoleProjectRightsService.effective_role_access_level(user, @organisation, area)
      end
    end

    def highest(levels)
      rank = ProjectPermission.level_rank
      levels.max_by { |level| rank.fetch(level, 0) }
    end

    def load_users
      # Load users via a membership SUBQUERY (not the has_many-through association) so the
      # base User query carries no join — otherwise `includes(memberships:)` collides with the
      # through-join and silently fails to preload, making role_in_organisation query per user.
      membership_scope = (@member_scope || @organisation.memberships).active
      User.where(id: membership_scope.select(:user_id), active: true, deleted_at: nil)
          .includes(memberships: { role: :permissions })
          .to_a
          .sort_by { |user| [user.display_name.downcase, user.id] }
    end
  end
end
