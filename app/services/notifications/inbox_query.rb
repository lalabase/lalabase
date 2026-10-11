# frozen_string_literal: true

# The ONE owner of "which rows are this user's inbox, seen through a Personal
# Access Token": recipient = user, in_app channel, not archived, organisation
# within the token's reach and project within the token's project links of that
# organisation, or no project at all (system messages). Shared by
# GET /api/v1/notifications and the MCP tool list_notifications (D4), so the two
# surfaces cannot drift and the token's project scope holds on both. Before it,
# the HTTP endpoint stopped at the organisation: a token linked to one project
# listed the rows of every project.
#
# Reads across organisations WITHOUT a tenant (ActsAsTenant.without_tenant; the
# precedent is this endpoint and TimeSessionsController#open). That is why every
# filter is explicit HERE and nowhere else: the recipient filter is the ownership
# check, the reach is the token contract, and a caller only ever narrows what it
# gets. .call returns a loaded Page with the associations the Serializer reads
# preloaded; .relation is for a bulk write and runs inside the caller's
# without_tenant block.
#
# The argument contract lives here too, for both surfaces: an unusable value
# (status, since, organisation_id, project_id, page, per_page) raises
# InvalidArgument instead of silently taking a default, and a project_id or
# organisation_id outside what the token and the person reach raises a
# NotReachable with one wording per kind (the project's is the seam's own), so
# a missing one and one the token may not see read alike (no existence leak).
#
# Entry point: call
module Notifications
  class InboxQuery
    STATUSES = %w[unread read all].freeze
    DEFAULT_STATUS = 'unread'
    MAX_PER_PAGE = 100
    DEFAULT_PER_PAGE = 25
    # Far beyond any real inbox (100_000 pages of MAX_PER_PAGE rows), close
    # enough to keep (page - 1) * per_page inside PostgreSQL's OFFSET range: an
    # unbounded page number overflowed bigint and answered a 500.
    MAX_PAGE = 100_000
    # The wording Mcp::ToolCall answers for a project outside the token's scope.
    # Deliberately the same string on both sides (the seam's gate and this filter),
    # so a client cannot tell a missing project from a hidden one by the message.
    PROJECT_NOT_REACHABLE = 'Project not found or not accessible.'
    ORGANISATION_NOT_REACHABLE = 'Organisation not found or not accessible.'
    # A caller-supplied argument the query cannot honour. Both surfaces turn it
    # into their clean "bad input" answer (400 / tool error), never a 500.
    class InvalidArgument < ArgumentError; end
    # A filter the token or the person cannot reach (or that does not exist): the
    # HTTP API answers 404 like every other out-of-scope project, the MCP tool its
    # not_found. Both surfaces rescue this parent.
    class NotReachable < InvalidArgument; end
    class ProjectNotReachable < NotReachable; end
    class OrganisationNotReachable < NotReachable; end

    # by_organisation: [{ id:, name:, unread: }] per organisation in view (#organisations_in_view),
    # the unread_total slice split by organisation, zeros included. With an all-organisations
    # token it is the cockpit tile of every organisation (unread_count_parity_spec.rb).
    Page = Struct.new(:rows, :page, :per_page, :total, :unread_total, :since, :by_organisation, keyword_init: true)

    # @return [Page] rows by latest activity first, with actor/organisation/project/notifiable preloaded
    def self.call(user:, reach:, status: nil, since: nil, project_id: nil, organisation_id: nil, page: nil,
                  per_page: nil)
      new(user: user, reach: reach, status: status, since: since, project_id: project_id,
          organisation_id: organisation_id).page(page: page, per_page: per_page)
    end

    # The unpaginated rows for a bulk write or a member lookup. Lazy: the caller
    # runs it inside ActsAsTenant.without_tenant.
    def self.relation(user:, reach:, status: nil, since: nil, project_id: nil, include_archived: false)
      new(user: user, reach: reach, status: status, since: since, project_id: project_id,
          include_archived: include_archived).relation
    end

    def initialize(user:, reach:, status: nil, since: nil, project_id: nil, organisation_id: nil,
                   include_archived: false)
      @user = user
      @reach = reach
      @status = parse_status(status)
      @since = parse_since(since)
      @organisation_id = parse_organisation_id(organisation_id)
      @project_id = parse_project_id(project_id)
      @include_archived = include_archived
    end

    def page(page:, per_page:)
      page_number = parse_page(page)
      limit = parse_per_page(per_page)
      ActsAsTenant.without_tenant do
        rows = relation.limit(limit).offset((page_number - 1) * limit)
                       .includes(:actor, :organisation, :project, :notifiable).to_a
        preload_document_versions(rows)
        unread_by_organisation = base.unread.group(:organisation_id).count
        Page.new(rows: rows, page: page_number, per_page: limit, total: relation.count,
                 unread_total: unread_by_organisation.values.sum, since: @since,
                 by_organisation: by_organisation(unread_by_organisation))
      end
    end

    # Ordered by ACTIVITY, the same column the `since` cursor cuts on: a grouped
    # row (GroupKeyBuilder#update_existing_group) keeps its created_at, moves
    # last_event_at and turns unread again, so on created_at a polling client
    # would never see the second to tenth comment on a ticket, and a client that
    # advances `since` to the newest row of a page would skip rows further down
    # whose activity is newer. The id breaks ties, so rows of one fanout pass
    # cannot straddle a page boundary twice.
    def relation
      rel = base
      rel = rel.where('notifications.last_event_at > ?', @since) if @since
      status_filter(rel).order(last_event_at: :desc, id: :desc)
    end

    private

    # Everything except status and since: the slice `unread_total` counts over,
    # so the number next to a filtered page describes the same reach.
    def base
      rel = Notification.where(recipient_id: @user.id, channel: :in_app)
      rel = rel.inbox unless @include_archived
      rel = rel.where(organisation_id: @organisation_id) if @organisation_id
      rel = rel.where(project_id: @project_id) if @project_id
      within_reach(rel)
    end

    # One OR branch per organisation in reach: all of its rows, or (restricted
    # token) only the rows of the linked projects plus the project-less ones.
    # No organisation in reach means no rows, never all rows.
    #
    # Narrowed a second time by what the PERSON may currently see. The two are different
    # questions: a token's reach is written once when the token is made and never asked
    # again, while project access changes the day someone is taken off a project. A
    # notification needs both.
    #
    # Without the second narrowing this is the one door around the gate that FanoutService,
    # the inbox scope and EmailDeliveryJob all apply, and the widest one: for an
    # all_projects token the reach carries no project filter at all, so it would answer
    # with every project its owner has been removed from.
    def within_reach(rel)
      parts = @reach.organisation_ids.filter_map do |org_id|
        projects = currently_accessible_projects(org_id)
        next if projects.nil?

        inbox_query_readable_rows(rel, org_id)
      end
      parts.reduce { |acc, part| acc.or(part) } || rel.none
    end

    # The one rule of every inbox (Notification.readable, per area), narrowed to the
    # token's projects, for one organisation. Named so the per-organisation
    # resolution of the AREAS has a frame in the Prosopite stack, like
    # inbox_query_current_access below: for a role with rights in all projects it
    # reads one exclusion list per area and organisation, bounded by the
    # organisations the token names.
    def inbox_query_readable_rows(rel, org_id)
      Notification.readable(rel.where(organisation_id: org_id), @user, reach_organisations[org_id],
                            within: @reach.project_ids_for(org_id))
    end

    # The projects of one organisation the user may currently reach, as a RELATION, or nil
    # when they are no longer an active member of it.
    #
    # nil drops the whole branch, its project-less system messages included. Leaving an
    # organisation should not keep delivering its news, and unlike the inbox (which can only
    # ever render an organisation the user is inside of) this query can be asked about one
    # the token still names.
    def currently_accessible_projects(org_id)
      @accessible_projects ||= {}
      return @accessible_projects[org_id] if @accessible_projects.key?(org_id)

      @accessible_projects[org_id] = inbox_query_current_access(reach_organisations[org_id])
    end

    # Whether a caller-supplied project is one the person can reach TODAY, not merely one the
    # token names. Without it the endpoint grows a third answer: a project outside the reach
    # 404s, one inside it but lost answers 200 with an empty list, and telling those two apart
    # is exactly the existence signal the class header promises not to give.
    def currently_reachable_project?(project)
      projects = currently_accessible_projects(project.organisation_id)
      return false if projects.nil?

      projects.exists?(id: project.id)
    end

    # Named so the per-organisation resolution has its own frame in the Prosopite stack: the
    # bounded per-tenant loop is declared there once, by this name, instead of silencing
    # ProjectAccessService for every other caller in the app.
    #
    # ⚠️ Returns a RELATION, never a plucked array. For an account admin (or a global role
    # right) this IS the organisation's whole project list, so plucking wrote every project id
    # of that organisation into the statement: a predicate that means "no filter", spelled out
    # in full, growing with the data and scattering the plan cache. As a subquery it stays one
    # short predicate whatever the size. Same shape ProjectPolicy::Scope uses. Safe to build
    # here: a relation built inside without_tenant still renders tenant-free later (measured).
    #
    # ⚠️ Area-blind, deliberately and for now. accessible_projects without an `area:` answers
    # "may see the project at ALL", so someone left with access to a single area of a project
    # still receives its ticket notifications. The inbox answers identically (both ask
    # Notification.source_projects_for), so this is the older question, not one this seam
    # invented. Pinned in inbox_query_spec.rb so it stays a decision rather than an accident.
    #
    # The project set is Notification.source_projects_for, the same one the cockpit tile, the
    # badge and the inbox list count by (active projects only; until 2026-10-02 this took
    # archived ones too and an account admin's token counted more than the tile). It cannot
    # go through Notification.accessible_for itself, because the question spans several
    # organisations and that scope takes exactly one. One difference remains on purpose:
    # accessible_for lets every project-less row through, this drops them with an
    # organisation the user has left. The gate table in docs/architektur/seiteneffekt_ketten.md
    # names both owners.
    def inbox_query_current_access(organisation)
      return nil unless organisation
      return nil unless AccessCheck::ProjectAccessService.active_member?(@user, organisation)

      ActsAsTenant.without_tenant do
        Notification.source_projects_for(@user, organisation)
      end
    end

    def by_organisation(counts)
      organisations_in_view.map { |org| { id: org.id, name: org.name, unread: counts.fetch(org.id, 0) } }
    end

    # The organisations the counts are reported for: those in reach where the person is still
    # an active member (within_reach drops the others, rows and all), only the organisation of
    # project_id when one is given, in the order of Organisation.by_name (reach_organisations
    # is loaded in it, and a Hash keeps that order). currently_accessible_projects is memoised
    # by within_reach, so this costs no query of its own.
    def organisations_in_view
      organisations = reach_organisations.values.reject { |org| currently_accessible_projects(org.id).nil? }
      organisations = organisations.select { |org| org.id == @project_organisation_id } if @project_id
      organisations = organisations.select { |org| org.id == @organisation_id } if @organisation_id
      organisations
    end

    # Loaded in ONE query rather than per branch: the org lookup itself has no business
    # being the thing that repeats. without_tenant because this walks several organisations
    # while Project and friends are tenant-scoped; a tenant left set by the caller would
    # silently empty every organisation but one.
    def reach_organisations
      @reach_organisations ||= ActsAsTenant.without_tenant do
        Organisation.where(id: @reach.organisation_ids).by_name.index_by(&:id)
      end
    end

    # The polymorphic preload stops at the notifiable itself. Document#title
    # reads current_version, a tenanted belongs_to the Serializer touches per row;
    # without this a page of document rows costs one query per row.
    def preload_document_versions(rows)
      documents = rows.filter_map(&:notifiable).grep(Document)
      return if documents.empty?

      ActiveRecord::Associations::Preloader.new(records: documents, associations: :current_version).call
    end

    def status_filter(rel)
      case @status
      when 'read' then rel.read
      when 'all' then rel
      else rel.unread
      end
    end

    def parse_status(value)
      raw = value.to_s.strip.downcase
      return DEFAULT_STATUS if raw.empty?
      return raw if STATUSES.include?(raw)

      raise InvalidArgument, "invalid status #{value.inspect} (expected one of #{STATUSES.join(', ')})"
    end

    # The bound is a storable ISO 8601 timestamp (Lalabase::IsoTimestamp owns
    # that rule); absent means no bound, unusable means refused.
    def parse_since(value)
      raw = value.to_s.strip
      return nil if raw.empty?

      Lalabase::IsoTimestamp.parse(raw) ||
        raise(InvalidArgument, "invalid since #{value.inspect} (expected an ISO 8601 timestamp)")
    end

    # A malformed id is refused before it reaches the database (ActiveRecord
    # would cast it to NULL, the project-less rows). A well-formed id is then
    # resolved WITHOUT a tenant and checked against the reach, exactly like the
    # seam's own gate (Mcp::ToolCall#authorized_project).
    def parse_project_id(value)
      raw = value.to_s.strip
      return nil if raw.empty?
      raise InvalidArgument, "invalid project_id #{value.inspect} (expected a UUID)" unless Lalabase::Uuid.valid?(raw)

      project = ActsAsTenant.without_tenant { Project.find_by(id: raw) }
      raise ProjectNotReachable, PROJECT_NOT_REACHABLE unless @reach.project?(project)
      raise ProjectNotReachable, PROJECT_NOT_REACHABLE unless currently_reachable_project?(project)
      # With organisation_id as well, the project must lie in it: a project of
      # another organisation is no row of this inbox.
      raise ProjectNotReachable, PROJECT_NOT_REACHABLE if @organisation_id && project.organisation_id != @organisation_id

      @project_organisation_id = project.organisation_id
      raw
    end

    # Like project_id: a malformed id is refused before the database. A
    # well-formed one is brought to the canonical spelling (it is compared as a
    # string with the ids of reach_organisations) and must be an organisation of
    # the token's reach where the person is still an active member.
    # currently_accessible_projects answers nil for both failures (an organisation
    # outside the reach is not among reach_organisations) and for one that does
    # not exist, so all read alike.
    def parse_organisation_id(value)
      raw = value.to_s.strip
      return nil if raw.empty?

      id = Lalabase::Uuid.dashed(raw) ||
           raise(InvalidArgument, "invalid organisation_id #{value.inspect} (expected a UUID)")
      raise OrganisationNotReachable, ORGANISATION_NOT_REACHABLE if currently_accessible_projects(id).nil?

      id
    end

    # Absent means the first page; below 1 is read as 1 (the old clamp); a value
    # that is not a whole number, or a page no inbox has, is refused. Both
    # surfaces hand strings in (query string) or integers (JSON); an Array or a
    # nested hash arrives as neither and is refused too, where `.to_i` on it
    # used to raise NoMethodError into a 500.
    def parse_page(value)
      number = parse_integer(value, name: 'page')
      return 1 if number.nil?
      raise InvalidArgument, "invalid page #{value.inspect} (at most #{MAX_PAGE})" if number > MAX_PAGE

      [number, 1].max
    end

    def parse_per_page(value)
      number = parse_integer(value, name: 'per_page')
      return DEFAULT_PER_PAGE if number.nil? || number <= 0

      [number, MAX_PER_PAGE].min
    end

    # nil for absent; the Integer for a whole number (JSON integer or a numeric
    # string); InvalidArgument for anything else.
    def parse_integer(value, name:)
      return value.to_i if value.is_a?(Numeric)

      raw = value.is_a?(String) ? value.strip : nil
      return nil if raw.nil? && value.nil?
      return nil if raw && raw.empty?

      Integer(raw, 10, exception: false) ||
        raise(InvalidArgument, "invalid #{name} #{value.inspect} (expected a whole number)")
    end
  end
end
