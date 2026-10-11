# frozen_string_literal: true

# Single source of truth for "who is effectively on this project, and why".
#
# Builds the candidate user set (everyone in the org the viewer may see, plus anyone
# holding an explicit grant) and resolves each through ProjectMemberAccessResolver, so
# every result carries effective access *and* provenance (:admin / :direct / :role /
# :none). users_visible_to already folds org-wide users (account admins + global-role
# members) into the candidate set for every viewer, so implicit members surface here too
# — not just explicit ProjectPermission grants.
#
# Used by BOTH the Team management page (ProjectPermissionsController) and the project
# dashboard "TEAM" widget (Dashboard::TeamMembersComponent) so the two can never drift
# on who counts as a member. Preloads memberships -> role -> permissions so the resolver
# stays query-free (per-role memo), plus the avatar attachment the name circles need.
# Regression-guarded by the resolver + component specs.
module AccessCheck
  class ProjectTeamMembers
    def initialize(project:, current_user:)
      @project = project
      @organisation = project.organisation
      @current_user = current_user
    end

    # All resolved MemberAccess view-models: members (any access) + add-candidates (none).
    def all
      @all ||= ProjectMemberAccessResolver
               .new(project: @project, current_user: @current_user)
               .resolve(candidate_users)
    end

    # Only those with effective access from any source (admin / direct / role).
    # Blocked members are excluded: they carry an explicit grant but no access,
    # so they do not belong in a "who works on this project" list.
    def with_access
      all.select(&:access?)
    end

    # Everyone the Team MANAGEMENT page must show: the people with access plus the
    # blocked ones, because a block that becomes invisible can never be lifted.
    def on_roster
      all.select { |member| member.access? || member.blocked? }
    end

    private

    def candidate_users
      visible_ids = ProjectAccessService.users_visible_to(@current_user, @organisation).select(:id)
      member_ids = @project.project_permissions.select(:user_id)
      # avatar_attachment/blob: the dashboard TEAM widget draws every member through
      # Neo::Users::NameComponent in circle mode, and its attached? check is one query per
      # member without this preload (name_component.rb:27). The Team management page draws
      # no circles today but shares this query, and pays one extra preload for it.
      @organisation.users
                   .where(id: visible_ids).or(@organisation.users.where(id: member_ids))
                   .includes(memberships: { role: :permissions }, avatar_attachment: :blob)
    end
  end
end
