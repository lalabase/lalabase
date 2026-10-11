# frozen_string_literal: true

# Resolves, for each user, their *effective* access to a project's areas PLUS the
# provenance of that access (explicit project grant, account-admin, or a global role
# right). The Team UI uses this to show not just "what" a member may do, but "why"
# they are on the project and "where" to change it.
#
#   source legend
#   :admin  -> account_admin role: full write everywhere, locked here, link to role
#   :direct -> explicit ProjectPermission row: editable inline here
#   :role   -> global "*_all_projects" role right: inherited, overridable via explicit grant
#   :none   -> no access at all (candidate for the add-member picker)
#
# BLOCKED MEMBERS
#   A :direct row that grants nothing while a role right waits behind it is a
#   deliberate block (see #blocked?), not a half-configured member. Actors::
#   RevokeProjectMember writes exactly that shape when a member cannot simply be
#   dropped, because ProjectAccessService lets an explicit no_access beat a role
#   right. Such a member is off the project (#access? is false) but stays on the
#   Team page so the block remains visible and reversible.
#
# N+1 AVOIDANCE
#   Role-derived rights are identical for every user sharing a role, so the per-area
#   effective levels are computed ONCE per distinct role_id and memoised. This only
#   stays query-free if the caller preloads `memberships: { role: :permissions }` on
#   the users (and the project's project_permissions) — then role_in_organisation and
#   role.has_permission? read from memory. See AccessCheck::ProjectTeamMembers, which
#   builds that preloaded candidate set for both the Team page and the dashboard widget.
#   Regression-guarded by spec/services/access_check/project_member_access_resolver_spec.rb.
class AccessCheck::ProjectMemberAccessResolver
  # Single source of truth for the area list — new areas (like :documentation)
  # appear on the Team page automatically. Do not enumerate them here.
  AREAS = ProjectPermission.access_areas

  # Per-area effective access. `inherited` = comes from admin/role (locked here), not
  # from an explicit project grant.
  Cell = Struct.new(:area, :level, :inherited, keyword_init: true)

  # Time tracking is a separate granular sub-system, summarised to a status label.
  # status: :full (admin) | :standard (model defaults) | :custom | :none
  TimeCell = Struct.new(:status, :inherited, :settings_permission, keyword_init: true)

  # role_override: would this person still have access if the explicit row went
  # away? That single fact drives both the Team page's remove button and the
  # actor behind it.
  MemberAccess = Struct.new(
    :user, :source, :role_title, :cells, :time, :permission, :is_self, :role_override,
    keyword_init: true
  ) do
    def access?     = source != :none && !blocked?
    def editable?   = source == :direct
    def admin?      = source == :admin
    def role_based? = source == :role

    # An explicit grant that gives nothing while a role right stands behind it.
    # The inference is sound because the add-member picker only ever offers users
    # WITHOUT access, so this shape cannot come from a freshly added member.
    def blocked?
      source == :direct && role_override && cells.values.all? { |cell| cell.level == 'no_access' }
    end
  end

  def initialize(project:, current_user:)
    @project = project
    @organisation = project.organisation
    @current_user = current_user
    @permissions_by_user_id = project.project_permissions.includes(:user).index_by(&:user_id)
    # Preload time-session rows once (keyed by user) so build_time never queries per member.
    @time_permissions_by_user_id = TimeSessionPermission.backed_by_project_access
                                                        .where(project_id: project.id).index_by(&:user_id)
    @role_levels = {} # memo: role_id (or :none) => { area => level }
  end

  # Build MemberAccess view-models for the given users.
  def resolve(users)
    users.map { |user| for_user(user) }
  end

  def for_user(user)
    permission = @permissions_by_user_id[user.id]
    role = user.role_in_organisation(@organisation)
    admin = role&.account_admin? || false
    role_override = !admin && role_grants_any?(user, role)

    source =
      if admin then :admin
      elsif permission then :direct
      elsif role_override then :role
      else
        :none
      end

    MemberAccess.new(
      user: user,
      source: source,
      role_title: role&.title,
      cells: build_cells(user, role, admin, permission, source),
      time: build_time(user, admin, permission),
      permission: permission,
      is_self: user.id == @current_user.id,
      role_override: role_override
    )
  end

  private

  def build_cells(user, role, admin, permission, source)
    AREAS.index_with do |area|
      if admin
        Cell.new(area: area, level: 'read_write', inherited: true)
      elsif permission
        Cell.new(area: area, level: permission.public_send("#{area}_access"), inherited: false)
      elsif source == :role
        Cell.new(area: area, level: role_levels(user, role)[area], inherited: true)
      else
        Cell.new(area: area, level: 'no_access', inherited: true)
      end
    end
  end

  def build_time(user, admin, permission)
    return TimeCell.new(status: :full, inherited: true, settings_permission: nil) if admin

    if permission
      tsp = @time_permissions_by_user_id[user.id] || TimeSessionPermission.new(project: @project, user: user)
      TimeCell.new(status: time_status(tsp), inherited: false, settings_permission: permission)
    else
      TimeCell.new(status: :none, inherited: true, settings_permission: nil)
    end
  end

  def time_status(tsp)
    own = tsp.can_create_own? || tsp.can_view_own? || tsp.can_edit_own? || tsp.can_delete_own?
    all = tsp.can_view_all? || tsp.can_edit_all? || tsp.can_delete_all?
    return :none unless own || all

    # "standard" == the model's default set (own rights on, all rights off)
    standard = tsp.can_create_own? && tsp.can_view_own? && tsp.can_edit_own? &&
               tsp.can_delete_own? && !all
    standard ? :standard : :custom
  end

  # Does this role grant ANY global area right? (admin handled before this is reached)
  # Asks RoleProjectRightsService for the rule so the Team page and
  # Actors::RevokeProjectMember cannot answer it differently; the per-role memo
  # below only decides WHERE the levels come from, never WHAT counts as a grant.
  def role_grants_any?(user, role)
    return false unless role

    AccessCheck::RoleProjectRightsService.any_grant?(role_levels(user, role))
  end

  # Per-role effective levels for every area in AREAS, computed ONCE per role_id and memoised.
  # Reuses RoleProjectRightsService, which is query-free here thanks to the caller's preload.
  def role_levels(user, role)
    key = role&.id || :none
    @role_levels[key] ||= AREAS.index_with do |area|
      AccessCheck::RoleProjectRightsService.effective_role_access_level(user, @organisation, area)
    end
  end
end
