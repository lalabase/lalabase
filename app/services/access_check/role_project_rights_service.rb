# frozen_string_literal: true

class AccessCheck::RoleProjectRightsService
  attr_reader :user, :organisation

  def initialize(user, organisation)
    @user = user
    @organisation = organisation
  end

  # Checks whether the user has global read permissions for a specific area via their role
  def has_global_read_access?(area = nil)
    # Account admins always have access
    return true if user.account_admin_in?(organisation)

    # Check area-specific permissions if an area was provided
    if area
      permission_name = "read_access_#{area}_all_projects"
      return user.has_permission_in_organisation?(organisation, 'projects', permission_name)
    end

    # Check whether any area-specific read permission exists
    ProjectPermission.access_areas.any? do |a|
      permission_name = "read_access_#{a}_all_projects"
      user.has_permission_in_organisation?(organisation, 'projects', permission_name)
    end
  end

  # Checks whether the user has global write permissions for a specific area via their role
  def has_global_write_access?(area = nil)
    # Account admins always have access
    return true if user.account_admin_in?(organisation)

    # Check area-specific permissions if an area was provided
    if area
      permission_name = "write_access_#{area}_all_projects"
      return user.has_permission_in_organisation?(organisation, 'projects', permission_name)
    end

    # Check whether any area-specific write permission exists
    ProjectPermission.access_areas.any? do |a|
      permission_name = "write_access_#{a}_all_projects"
      user.has_permission_in_organisation?(organisation, 'projects', permission_name)
    end
  end

  # Returns the effective access level for an area, based on role permissions
  def effective_role_access_level(area)
    if has_global_write_access?(area)
      'read_write'
    elsif has_global_read_access?(area)
      'read_only'
    else
      'no_access'
    end
  end

  # Does the user have read permissions for this area via their role?
  def can_read?(area)
    has_global_read_access?(area) || has_global_write_access?(area)
  end

  # Does the user have write permissions for this area via their role?
  def can_write?(area)
    has_global_write_access?(area)
  end

  # Class methods for checking role permissions
  class << self
    # Returns a list of all project areas for which global role permissions apply
    delegate :access_areas, to: :ProjectPermission

    # Checks whether the user has global read permissions via their role
    def has_global_read_access?(user, organisation, area = nil)
      # Account admins always have access
      return true if user.account_admin_in?(organisation)

      # Check area-specific permissions if an area was provided
      if area
        permission_name = "read_access_#{area}_all_projects"
        return user.has_permission_in_organisation?(organisation, 'projects', permission_name)
      end

      # Check whether any area-specific read permission exists
      ProjectPermission.access_areas.any? do |a|
        permission_name = "read_access_#{a}_all_projects"
        user.has_permission_in_organisation?(organisation, 'projects', permission_name)
      end
    end

    # Checks whether the user has global write permissions via their role
    def has_global_write_access?(user, organisation, area = nil)
      # Account admins always have access
      return true if user.account_admin_in?(organisation)

      # Check area-specific permissions if an area was provided
      if area
        permission_name = "write_access_#{area}_all_projects"
        return user.has_permission_in_organisation?(organisation, 'projects', permission_name)
      end

      # Check whether any area-specific write permission exists
      ProjectPermission.access_areas.any? do |a|
        permission_name = "write_access_#{a}_all_projects"
        user.has_permission_in_organisation?(organisation, 'projects', permission_name)
      end
    end

    # Returns the effective access level for an area
    def effective_role_access_level(user, organisation, area)
      if has_global_write_access?(user, organisation, area)
        'read_write'
      elsif has_global_read_access?(user, organisation, area)
        'read_only'
      else
        'no_access'
      end
    end

    # Does the user's ROLE alone put them on every project of the org?
    #
    # ONE owner of that question, because two places must answer it identically:
    # ProjectMemberAccessResolver (to mark a Team row as role-backed) and
    # Actors::RevokeProjectMember (to decide whether removing a member means
    # dropping their grant or blocking it). Drift between the two shows up as a
    # remove button that reports success and changes nothing.
    #
    # Returns true for an account admin too; a caller that treats admins
    # differently must check account_admin_in? BEFORE asking this.
    def grants_any_project_right?(user, organisation)
      any_grant?(project_rights_by_area(user, organisation))
    end

    # Per-area levels, keyed by area. Split out so a caller that already memoises
    # those levels per role (the resolver's N+1 defence) can reuse #any_grant?
    # instead of re-deriving the rule.
    def project_rights_by_area(user, organisation)
      ProjectPermission.access_areas.index_with do |area|
        effective_role_access_level(user, organisation, area)
      end
    end

    def any_grant?(levels_by_area)
      levels_by_area.values.any? { |level| level != 'no_access' }
    end
  end
end
