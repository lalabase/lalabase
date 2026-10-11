# frozen_string_literal: true

# Helper module for permission testing
module PermissionTestHelper
  # Sets up proper permission for a user on a project
  def setup_project_permission(user, project, area, access_level)
    # First delete any existing permission to avoid conflicts
    ProjectPermission.where(user: user, project: project).delete_all

    # Create a new permission with the desired access level
    permission = ProjectPermission.create!(
      user: user,
      project: project,
      "#{area}_access" => access_level
    )

    # Force reload associations to ensure they're up to date
    user.reload
    project.reload

    # Return the permission for inspection if needed
    permission
  end

  # Sets up role with permission
  def setup_role_permission(role, area, action_type)
    # Clear existing permissions for this area if any exist
    action = action_type == :read ? "read_access_#{area}_all_projects" : "write_access_#{area}_all_projects"
    Permission.where(role: role, category: 'projects', action: action).delete_all

    # Create a new permission
    permission = Permission.create!(
      role: role,
      category: 'projects',
      action: action,
      allowed: true
    )

    # Force role reload to refresh permissions cache
    role.reload

    # Return the permission for inspection if needed
    permission
  end

  # Sets up user as an organization admin
  def setup_admin_role(user, organisation)
    # Create admin role if it doesn't exist
    admin_role = Role.find_or_create_by!(
      organisation: organisation,
      title: 'account_admin',
      description: 'Administrator with full access'
    )

    # Assign admin role to user's membership
    membership = Membership.find_or_create_by!(user: user, organisation: organisation)
    membership.update!(role: admin_role, active: true)

    # Force reload
    user.reload
    organisation.reload

    # Return the admin role
    admin_role
  end

  # Sets up a user with a specific role
  def setup_user_with_role(user, organisation, role)
    # Assign role to user's membership
    membership = Membership.find_or_create_by!(user: user, organisation: organisation)
    membership.update!(role: role, active: true)

    # Force reload
    user.reload
    organisation.reload

    # Return the membership
    membership
  end

  # A Personal Access Token belongs to a person and cannot reach further than that person
  # does. Notifications::InboxQuery narrows the token's reach by the owner's CURRENT project
  # access, so a token owner who is not an active member reaches nothing at all, and one
  # without a grant reaches none of the organisation's projects.
  #
  # Fixtures that hand out a token and nothing else describe an account shape that cannot
  # exist, and every example built on one measures the reach against a non-member. This is
  # the realistic precondition, written once here rather than as the same comment in every
  # spec that needs it.
  #
  # Deliberately additive: it never widens an existing membership or role, it only supplies
  # what is missing, so a spec that sets up its own rights keeps them.
  def make_token_owner_a_member(user, organisation, projects: [], area: :tickets, access: 'read_write')
    ActsAsTenant.with_tenant(organisation) do
      activate_membership(user, organisation)
      Array(projects).each { |project| grant_project_access(user, project, area, access) }
    end

    # @role_cache stores nil results too (it uses key?, not ||=), so a spec that asks before
    # granting would keep the stale "no role here". @active_member_cache only memoises truthy
    # answers and could not go stale that way; it is cleared alongside so the two never have
    # to be reasoned about separately.
    user.instance_variable_set(:@active_member_cache, nil)
    user.instance_variable_set(:@role_cache, nil)
    user
  end

  # "make a member" has to mean it. A row that exists but is inactive is not a membership for
  # any question the gate asks (ProjectAccessService#can? refuses a deactivated member before
  # it looks at anything else), so finding a row is not the same as being done.
  def activate_membership(user, organisation)
    membership = Membership.find_by(user_id: user.id, organisation_id: organisation.id)
    return create(:membership, user: user, organisation: organisation, active: true) if membership.nil?

    membership.update!(active: true) unless membership.active?
    membership
  end

  # ProjectPermission soft-deletes (default_scope on deleted_at) while its unique index counts
  # archived rows too. So `exists?` answers "no" over an archived grant and the create! behind
  # it raises RecordNotUnique. Reviving is what the production path does as well, through the
  # model's own owner of that idea.
  def grant_project_access(user, project, area, access)
    archived = ProjectPermission.archived_for(project: project, user: user)
    return archived.update!(deleted_at: nil, "#{area}_access" => access) if archived
    return if ProjectPermission.exists?(user_id: user.id, project_id: project.id)

    setup_project_permission(user, project, area, access)
  end
end

RSpec.configure do |config|
  config.include PermissionTestHelper
end
