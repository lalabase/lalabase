# frozen_string_literal: true

module AccessCheck
  # THE owner of project access. One rule on top of the grants: an ARCHIVED
  # project is closed to everyone but the account admins, in every entry point
  # below (the same answer ProjectPolicy#show? gives). Until 27.09.2026 only
  # show? knew that, and a direct link opened and saved tickets, notes and
  # documents of an archived project. The time domain follows the same rule
  # with one exception, own hours stay readable (TimeSessions::ViewingScope).
  # Guard: spec/requests/organisations/archived_project_access_spec.rb.
  class ProjectAccessService
    # Access column per area. Queries look the column up here instead of building
    # it from the area name, so no caller-supplied value ever reaches the SQL.
    AREA_COLUMNS = ProjectPermission.access_areas.index_with { |area| "#{area}_access" }.freeze

    # Instance methods for checks on a specific project
    attr_reader :user, :project, :organisation

    def initialize(user, project = nil)
      @user = user
      @project = project
      @organisation = project&.organisation || ActsAsTenant.current_tenant
      @project_permission = find_project_permission if project
    end

    # Main method: Checks whether the user may perform a specific action
    # for this project and this area
    def can?(action, area)
      # Base checks
      return false unless valid_project?
      return false unless self.class.active_member?(user, organisation)
      return true if admin_access?
      return false if project.archived?

      # Convert parameters to symbols for consistent processing
      action = action.to_sym
      area = normalize_area(area)

      # Check specific project permissions (take precedence)
      project_permission_result = check_project_permission(action, area)
      return project_permission_result unless project_permission_result.nil?

      # Check role permissions
      check_role_permission(action, area)
    end

    # Returns the concrete access level (no_access, read_only, read_write) for an area
    def access_level(area)
      # Base checks
      return 'no_access' unless valid_project?
      return 'no_access' unless self.class.active_member?(user, organisation)
      return 'read_write' if admin_access?
      return 'no_access' if project.archived?

      area = normalize_area(area)

      # Check specific project permissions (take precedence)
      project_level = project_permission_level(area)
      return project_level if project_level

      # Check role permissions
      role_level = role_permission_level(area)
      return role_level if role_level

      # Default: No access
      'no_access'
    end

    #
    # Private helper methods
    #
    private

    # Normalizes the area name (posts → tickets)
    def normalize_area(area)
      area = area.to_sym
      area == :posts ? :tickets : area
    end

    # Finds the project access permission for the current user and the project
    def find_project_permission
      project ? ProjectPermission.find_by(user: user, project: project) : nil
    end

    # Checks whether a valid project and an organisation are defined
    def valid_project?
      project&.organisation
    end

    # Checks whether the user has admin rights
    def admin_access?
      user.account_admin_in?(organisation)
    end

    # Checks the user's specific project permission
    # Returns true/false when it can be decided, or nil when no explicit
    # project permission is present
    def check_project_permission(action, area)
      return nil unless @project_permission

      # Check if area exists in ProjectPermission
      unless ProjectPermission.access_areas.include?(area)
        Rails.logger.warn "Unbekannter Zugangsbereich: #{area}"
        return false
      end

      access_value = @project_permission.public_send("#{area}_access")

      # If no_access is explicitly set, this takes precedence over role rights
      return false if access_value == 'no_access'

      # Check read access
      return true if action == :read && %w[read_only read_write].include?(access_value)

      # Check write access
      return true if action == :write && access_value == 'read_write'

      # No explicit permission found, check role rights
      nil
    end

    # Checks the user's role permissions
    def check_role_permission(action, area)
      case action
      when :read
        has_read_permission_in_role?(area) || has_write_permission_in_role?(area)
      when :write
        has_write_permission_in_role?(area)
      else
        false
      end
    end

    # Checks whether the user has read rights via their role
    def has_read_permission_in_role?(area)
      permission_name = "read_access_#{area}_all_projects"
      user.has_permission_in_organisation?(organisation, 'projects', permission_name)
    end

    # Checks whether the user has write rights via their role
    def has_write_permission_in_role?(area)
      permission_name = "write_access_#{area}_all_projects"
      user.has_permission_in_organisation?(organisation, 'projects', permission_name)
    end

    # Determines the access level based on project permissions
    def project_permission_level(area)
      return nil unless @project_permission

      # If a local permission exists, it always takes precedence - even no_access
      @project_permission.public_send("#{area}_access")
    end

    # Determines the access level based on role permissions
    def role_permission_level(area)
      return 'read_write' if has_write_permission_in_role?(area)
      return 'read_only' if has_read_permission_in_role?(area)

      nil
    end

    #
    # Class methods for cross-project checks
    #
    class << self
      # THE owner of the "active membership" rule (#603).
      #
      # Every entry point of this service asks this FIRST, before the account_admin
      # shortcut: the same order ProjectPolicy#area_access? uses, where the rule
      # already lived. Before this, the per-record path refused a deactivated member
      # while the list scopes still handed out rows, so the answer depended on which
      # door the question came through; four callers had grown their own copy of the
      # check (ChatPolicy::Scope, Lalabase::Tools::Scope, Chats::OwnerBackfill and
      # the policy path itself).
      #
      # Deliberately BEFORE the admin shortcut: role_in_organisation does not filter
      # on membership.active either, so a deactivated account_admin used to receive
      # scope.all from every list while show? denied them.
      #
      # Callers that reach past this service keep their own check: an org-wide
      # assistant thread has no project at all (ChatPolicy::Scope's org branch), so
      # no amount of project reach can speak for it.
      def active_member?(user, organisation)
        return false unless user && organisation

        user.active_member_of_organisation?(organisation)
      end

      # Checks whether the user may access the project (in general)
      def can_access_project?(user, project)
        # Basic checks
        return false unless project&.organisation
        return false unless active_member?(user, project.organisation)
        return true if user.account_admin_in?(project.organisation)
        return false if project.archived?

        # Create an instance for detailed checks
        service = new(user, project)

        # Check read access to all areas
        ProjectPermission.access_areas.each do |area|
          return true if service.can?(:read, area)
        end

        # No access in any area
        false
      end

      # The projects can_access_project? opens, as ids, for one organisation in one go: read
      # access in at least one area of ProjectPermission. Narrower than accessible_projects
      # without an area, which also counts a role that holds nothing but time tracking.
      # For a list whose ids a caller then takes through the gate.
      def openable_project_ids(user, organisation)
        ProjectPermission.access_areas.flat_map do |area|
          accessible_project_ids(user, organisation, action: :read, area: area)
        end.uniq
      end

      # Returns the list of all projects the user has access to.
      # Optional area/action filtering: only projects in which the user may perform
      # the desired action for that area.
      # Always returns a lazy ActiveRecord::Relation (no eager pluck).
      def accessible_projects(user, organisation, action: :read, area: nil)
        # Basic checks
        return Project.none unless organisation
        return Project.none unless active_member?(user, organisation)
        return organisation.projects if user.account_admin_in?(organisation)

        if area
          # Area-specific: only projects in which the user has access for that area
          area = normalize_area(area)
          action = action.to_sym
          has_global = has_global_permission_for_area?(user, organisation, action, area)

          if has_global
            # Global access: all projects MINUS those with explicit no_access for that area
            excluded_ids = find_excluded_project_ids_for_area(user, organisation, area)
            organisation.projects.active.where.not(id: excluded_ids)
          else
            # Only projects with an explicit ProjectPermission for that area
            project_ids = find_project_ids_with_area_access(user, organisation, action, area)
            organisation.projects.active.where(id: project_ids)
          end
        else
          # Without area: projects in which the user has access to any area
          role = user.role_in_organisation(organisation)
          has_global = role && has_global_access_in_role?(role)

          if has_global
            excluded_project_ids = find_explicitly_excluded_project_ids(user, organisation)
            organisation.projects.active.where.not(id: excluded_project_ids)
          else
            find_projects_with_local_permissions(user, organisation)
          end
        end
      end

      # Returns the project IDs the user has access to for a specific area.
      # SQL-based (no N+1), optimized for policy scopes.
      def accessible_project_ids(user, organisation, action: :read, area: :tickets)
        return [] unless organisation
        return [] unless active_member?(user, organisation)

        area = normalize_area(area)
        action = action.to_sym

        return organisation.projects.pluck(:id) if user.account_admin_in?(organisation)

        # Check global role permissions for this area
        has_global = has_global_permission_for_area?(user, organisation, action, area)

        if has_global
          # Global access: all projects MINUS those with explicit no_access for that area
          excluded_ids = find_excluded_project_ids_for_area(user, organisation, area)
          organisation.projects.active.where.not(id: excluded_ids).pluck(:id)
        else
          # Only projects with an explicit ProjectPermission for that area
          find_project_ids_with_area_access(user, organisation, action, area)
        end
      end

      # Project ids where `user` may WRITE meetings — the SINGLE source for the
      # participant-claim reach. The matcher, the actor and the policy all go
      # through this, so the authorization scope cannot silently drift across the
      # three (a security-adjacent DRY: one place decides "which meetings a claim
      # may touch").
      def writable_meetings_project_ids(user, organisation)
        accessible_project_ids(user, organisation, action: :write, area: :meetings)
      end

      # Inverse query: returns all users who can access a specific project.
      # Correctly accounts for no_access overrides.
      def users_with_access(project, action = :read, area = :tickets)
        organisation = project.organisation
        area = normalize_area(area)
        action = action.to_sym

        # 1. Admin user IDs
        admin_role_ids = organisation.roles.where(title: 'account_admin').pluck(:id)
        admin_user_ids = organisation.memberships.where(role_id: admin_role_ids).pluck(:user_id)

        # An archived project is the admins' alone (see the class comment).
        return User.where(id: admin_user_ids) if project.archived?

        # 2. Users with global role rights for this area
        global_role_ids = find_global_role_ids(organisation, action, area)
        global_user_ids = organisation.memberships.where(role_id: global_role_ids).pluck(:user_id)

        # 3. NEW: From global users, exclude those who have an explicit no_access
        if global_user_ids.any?
          excluded_user_ids = ProjectPermission
                              .where(project: project, user_id: global_user_ids)
                              .where(AREA_COLUMNS.fetch(area) => ProjectPermission.public_send("#{area}_accesses")[:no_access])
                              .pluck(:user_id)
          global_user_ids -= excluded_user_ids
        end

        # 4. Users with direct ProjectPermissions
        direct_user_ids = find_direct_permission_user_ids(project, action, area)

        # 5. Union
        all_user_ids = (admin_user_ids + global_user_ids + direct_user_ids).uniq
        User.where(id: all_user_ids)
      end

      # All people the given user "knows": every person with access to at least
      # one of the projects accessible to this user (= union of users_with_access
      # over accessible_projects). Org admins/owners see the whole organisation. Supplies
      # the member-add picker (ProjectPermissions), the SmartFolder reference picker and
      # the org member list — so a user can only see/select identities from projects
      # they themselves have access to. ONE query group (no N+1): admin and global
      # role users are org-wide, direct permissions are loaded across all projects at
      # once.
      def users_visible_to(user, organisation, action: :read, area: :tickets)
        return User.none unless organisation
        return organisation.users if user.account_admin_in?(organisation)

        area = normalize_area(area)
        action = action.to_sym
        project_ids = accessible_project_ids(user, organisation, action: action, area: area)
        return User.none if project_ids.empty?

        admin_role_ids = organisation.roles.where(title: 'account_admin').pluck(:id)
        global_role_ids = find_global_role_ids(organisation, action, area)
        org_wide_user_ids = organisation.memberships
                                        .where(role_id: (admin_role_ids + global_role_ids).uniq)
                                        .pluck(:user_id)

        access_values = if action == :read
                          [ProjectPermission.public_send("#{area}_accesses")[:read_only],
                           ProjectPermission.public_send("#{area}_accesses")[:read_write]]
                        else
                          [ProjectPermission.public_send("#{area}_accesses")[:read_write]]
                        end
        # Hash form (not a raw SQL fragment) so the dynamic, whitelisted area column is quoted
        # by ActiveRecord — no SQL-string interpolation.
        direct_user_ids = ProjectPermission.where(project_id: project_ids)
                                           .where(AREA_COLUMNS.fetch(area) => access_values)
                                           .pluck(:user_id)

        User.where(id: (org_wide_user_ids + direct_user_ids).uniq)
      end

      private

      # Normalizes the area name (posts → tickets)
      def normalize_area(area)
        area = area.to_sym
        area == :posts ? :tickets : area
      end

      # Checks whether the user has global role rights for a specific area
      def has_global_permission_for_area?(user, organisation, action, area)
        if action == :read
          user.has_permission_in_organisation?(organisation, 'projects', "read_access_#{area}_all_projects") ||
            user.has_permission_in_organisation?(organisation, 'projects', "write_access_#{area}_all_projects")
        else
          user.has_permission_in_organisation?(organisation, 'projects', "write_access_#{area}_all_projects")
        end
      end

      # Finds project IDs where the user has explicit no_access for a specific area
      def find_excluded_project_ids_for_area(user, organisation, area)
        ProjectPermission.joins(:project)
                         .where(user_id: user.id, projects: { organisation_id: organisation.id })
                         .where(AREA_COLUMNS.fetch(area) => ProjectPermission.public_send("#{area}_accesses")[:no_access])
                         .pluck(:project_id)
      end

      # Finds project IDs with an explicit ProjectPermission for an area
      def find_project_ids_with_area_access(user, organisation, action, area)
        access_values = if action == :read
                          [
                            ProjectPermission.public_send("#{area}_accesses")[:read_only],
                            ProjectPermission.public_send("#{area}_accesses")[:read_write]
                          ]
                        else
                          [ProjectPermission.public_send("#{area}_accesses")[:read_write]]
                        end

        ProjectPermission.joins(:project)
                         .where(user_id: user.id, projects: { organisation_id: organisation.id, archived_at: nil })
                         .where(AREA_COLUMNS.fetch(area) => access_values)
                         .pluck(:project_id)
      end

      # Finds role IDs with global rights for an area
      def find_global_role_ids(organisation, action, area)
        read_role_ids = organisation.roles.joins(:permissions)
                                    .where(permissions: { category: 'projects', action: "read_access_#{area}_all_projects", allowed: true })
                                    .pluck(:id)
        write_role_ids = organisation.roles.joins(:permissions)
                                     .where(permissions: { category: 'projects', action: "write_access_#{area}_all_projects", allowed: true })
                                     .pluck(:id)

        if action == :read
          (read_role_ids + write_role_ids).uniq
        else
          write_role_ids
        end
      end

      # Finds user IDs with direct ProjectPermissions
      def find_direct_permission_user_ids(project, action, area)
        access_values = if action == :read
                          [
                            ProjectPermission.public_send("#{area}_accesses")[:read_only],
                            ProjectPermission.public_send("#{area}_accesses")[:read_write]
                          ]
                        else
                          [ProjectPermission.public_send("#{area}_accesses")[:read_write]]
                        end

        project.project_permissions
               .where(AREA_COLUMNS.fetch(area) => access_values)
               .pluck(:user_id)
      end

      # Finds projects the user has access to via local project permissions
      def find_projects_with_local_permissions(user, organisation)
        # Collect project IDs from the project permissions
        project_ids = []

        ProjectPermission.access_areas.each do |area|
          # Find projects with read_only or read_write access in the respective area
          read_permissions = find_project_permission_ids_with_read_access(user, organisation, area)
          project_ids.concat(read_permissions)
        end

        # Fetch the projects for the collected IDs
        organisation.projects.active.where(id: project_ids.uniq)
      end

      # Finds project IDs where the user has read rights for a specific area
      def find_project_permission_ids_with_read_access(user, organisation, area)
        ProjectPermission.joins(:project)
                         .where(
                           user_id: user.id,
                           projects: { organisation_id: organisation.id }
                         )
                         .where(
                           AREA_COLUMNS.fetch(area) => [
                             ProjectPermission.public_send("#{area}_accesses")[:read_only],
                             ProjectPermission.public_send("#{area}_accesses")[:read_write]
                           ]
                         )
                         .pluck(:project_id)
      end

      # Checks whether a role has global access permissions
      def has_global_access_in_role?(role)
        # Use Permission.CATEGORIES to generate the correct permission string
        permission_keys = Permission::CATEGORIES[:projects].select do |key|
          key.start_with?('read_access_', 'write_access_') && key.end_with?('_all_projects')
        end

        permission_keys.any? { |key| role.has_permission?('projects', key) }
      end

      # Finds project IDs that are explicitly excluded from access
      def find_explicitly_excluded_project_ids(user, organisation)
        # Fetch all of the user's project permissions
        permissions = ProjectPermission.joins(:project)
                                       .where(
                                         user_id: user.id,
                                         projects: { organisation_id: organisation.id }
                                       )

        # For each project permission, check whether all areas are set to no_access
        excluded_ids = []

        permissions.each do |perm|
          # Check whether all areas are set to no_access
          all_no_access = true

          ProjectPermission.access_areas.each do |area|
            access_value = perm.public_send("#{area}_access")
            if access_value != 'no_access'
              all_no_access = false
              break
            end
          end

          # If all areas are no_access, add to the list of excluded IDs
          excluded_ids << perm.project_id if all_no_access
        end

        excluded_ids
      end
    end
  end
end
