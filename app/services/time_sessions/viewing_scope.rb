# frozen_string_literal: true

# How much booked time a user may see, as a tier, plus the matching narrowing of
# a time-session relation. Two entry points, ONE rule:
#
#   .call(user:, project:)                  -> the tier for a single project
#   .for_organisation(user:, organisation:) -> every project of an organisation
#                                              from one read of the permission
#                                              rows, plus #apply, #tier_for,
#                                              #projects and #sees_anything?
#
# ONE owner for the "all / own / none" rule. ProjectPolicy#area_access?
# (:time_sessions, :read) answers `can_view_own || can_view_all` and so cannot
# tell a user who may see only their own hours from one who may see everyone's.
# Every report over booked time (the chat tool SummarizeTimeSessions, the
# subject hours chip via SubjectTimeSummaryService) must decide that here, not
# by hand, and must never hand a can_view_own user a sum over all sessions.
#
# TimeSessionPolicy::Scope, the org-wide door every list and dashboard figure
# goes through, used to carry a second copy of the rule. That copy knew nothing
# about deactivated memberships, so a stale permission row behind a switched-off
# membership granted more time there than anywhere else in the app. It now calls
# .for_organisation (S0 of doc/projektzeiten_tabelle_plan.md).
#
# Fail-closed: only a PERSISTED permission row grants anything. The model's
# can_view_own default on an unsaved row (User#time_session_permission_for
# uses find_or_initialize_by) does not count, matching the area gate, which also
# sees nothing without a row.
#
# Precedence: deactivated membership -> :none, account admin of the
# organisation -> :all, can_view_all -> :all, can_view_own -> :own (creator ==
# user), else :none.
module TimeSessions
  class ViewingScope
    TIERS = %i[all own none].freeze

    # The precedence, written once. Both entry points read the order here, so it
    # cannot drift between them again.
    #
    # `admin` and `permission` are lazy on purpose: a deactivated member is never
    # asked whether they are an admin, and an admin is never asked for a
    # permission row. That is what keeps the single-project path at one query.
    module TierRule
      module_function

      # permission: () -> TimeSessionPermission or nil. => :all / :own / :none
      # archived: an archived project keeps members at their own hours at most
      # (AccessCheck::ProjectAccessService closes it; own hours stay readable).
      def call(active:, admin:, permission:, archived: false)
        return :none unless active
        return :all if admin.call

        row = permission.call
        return :none if row.nil?
        return (archived ? :own : :all) if row.can_view_all?
        return :own if row.can_view_own?

        :none
      end
    end
    private_constant :TierRule

    attr_reader :tier

    def self.call(user:, project:)
      new(user: user, project: project).call
    end

    # Every project of one organisation at once. The list, the dashboard tiles
    # and the briefing all ask about a whole organisation; asking .call per
    # project would cost a query per project.
    def self.for_organisation(user:, organisation:)
      OrganisationScope.new(user: user, organisation: organisation).call
    end

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    def call
      @tier = resolve_tier
      self
    end

    def all?
      tier == :all
    end

    def own?
      tier == :own
    end

    def none?
      tier == :none
    end

    # Narrows a relation of the project's time sessions to what the user may see.
    # :own restricts to the user's own bookings; :none yields an empty relation so a
    # caller that forgets to check the tier still leaks nothing.
    def apply(relation)
      case tier
      when :all then relation
      when :own then relation.where(creator_id: @user.id)
      else relation.none
      end
    end

    # The same rule for every project of one organisation, decided from ONE read
    # of the permission rows.
    class OrganisationScope
      def initialize(user:, organisation:)
        @user = user
        @organisation = organisation
      end

      def call
        @active = @user.present? && @organisation.present? &&
                  @user.active_member_of_organisation?(@organisation)
        # Same bar as the area gate (ProjectPolicy#active_member_of_record_organisation?):
        # an admin role behind a deactivated membership grants nothing (Zweitreview F4).
        @admin = @active && @user.account_admin_in?(@organisation)
        @tiers = build_tiers
        self
      end

      # :all / :own / :none for a project of THIS organisation. An id this object
      # never saw is :none, so nobody widens their view by asking about a project
      # they hold no rights in.
      def tier_for(project_id)
        return :none unless @active
        return :all if @admin

        @tiers.fetch(project_id, :none)
      end

      # Does this person see anybody else's time anywhere in this organisation?
      # The "nur meine Zeiten" switch is only a switch where the answer is yes;
      # for someone who sees only their own it filters a list down to itself.
      def sees_others?
        return false unless @active
        return true if @admin

        @tiers.value?(:all)
      end

      # Narrows a relation the caller has ALREADY scoped to this organisation.
      # For an admin the relation comes back untouched, which is only safe
      # because of that: TimeSessionPolicy::Scope hands in a tenant-scoped
      # relation, and so does every list path.
      def apply(relation)
        return relation.none unless @active
        return relation if @admin

        relation.where(project_id: project_ids_at(:all))
                .or(relation.where(project_id: project_ids_at(:own), creator_id: @user.id))
      end

      # The projects in which this person sees any time at all: every project
      # of the organisation for an admin, the ones at :all or :own for everybody
      # else. The list's project select reads this, so "which projects do I see
      # here" has the same owner as "which rows do I see".
      def projects
        return Project.none unless @active
        return Project.where(organisation_id: @organisation.id) if @admin

        Project.where(id: project_ids_at(:all) + project_ids_at(:own))
      end

      # Does this person see time anywhere in the organisation? The door to
      # the list itself: the menu entry and TimeSessionPolicy#index? ask here.
      def sees_anything?
        return false unless @active
        return true if @admin

        @tiers.values.any? { |tier| tier != :none }
      end

      private

      # Admins need no rows: they are :all everywhere in the organisation, and
      # asking would be a query for an answer already known.
      def build_tiers
        return {} unless @active && !@admin

        permission_rows.to_h do |row|
          [row.project_id, TierRule.call(active: true, admin: -> { false }, permission: -> { row },
                                         archived: row.project_archived_at.present?)]
        end
      end

      def permission_rows
        # The archive flag rides along in the same read (TierRule's archived:).
        @user.time_session_permissions
             .backed_by_project_access
             .joins(:project)
             .where(projects: { organisation_id: @organisation.id })
             .select('time_session_permissions.*', 'projects.archived_at AS project_archived_at')
      end

      def project_ids_at(tier)
        @tiers.select { |_project_id, project_tier| project_tier == tier }.keys
      end
    end

    private

    def resolve_tier
      return :none if @user.nil? || @project.nil?

      organisation = @project.organisation
      TierRule.call(
        active: @user.active_member_of_organisation?(organisation),
        admin: -> { @user.account_admin_in?(organisation) },
        permission: -> { @user.time_session_permissions.backed_by_project_access.find_by(project: @project) },
        archived: @project.archived?
      )
    end
  end
end
