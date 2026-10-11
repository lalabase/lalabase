# frozen_string_literal: true

module Dashboard
  # Cross-org "what needs me" aggregation for the cockpit (organisations#select).
  #
  # The ONLY per-org data source for that page. organisations#select runs with NO tenant
  # (skip_before_action :load_tenant_from_session) and require_tenant is true, so EVERY
  # acts_as_tenant read here is wrapped per org in ActsAsTenant.with_tenant — a tenanted
  # read outside this seam would raise NoTenantSet (a 500 on the whole page). The member-count
  # query stays in the controller because Membership is not tenant-scoped.
  #
  #   user.active_organisations.each do |org|
  #     with_tenant(org) do
  #       project_ids ── Notification.source_projects_for, once ──┬─ unread notifications (Notification.inbox_unread)
  #                                                              ├─ importance-filtered tickets (TicketPolicy::Scope + assigned_to)
  #                                                              └─ status-value lookup (closed | backlog)
  #     end
  #   end
  #
  # Security boundary per org: the project set of Notification.source_projects_for (the one inbox
  # rule, AccessCheck::ProjectAccessService with the org passed explicitly) and TicketPolicy::Scope
  # for the tickets. with_tenant sets the org the tenanted reads need, so the untenanted Membership
  # table cannot leak across orgs.
  #
  # "What needs me" = unread in-app notifications + the importance-filtered assigned ticket set.
  # Every unread notification is now actionable (not just mentions): the cockpit shows "what is
  # genuinely new". notification_count == the per-org unread tile count by construction, so they
  # share ONE relation and ONE COUNT (no double-build).
  #
  # The `importance` level controls which tickets are shown (and is the sort intent):
  #   :notifications -> no tickets (only the unread list)
  #   :important     -> assigned active tickets that are overdue OR high priority (the default)
  #   :all           -> all assigned active tickets (the original behaviour)
  #
  # Counts are exact (separate COUNT) and item lists are capped at TOP_N: a roll-up, never a
  # full inbox, and bounded queries (no load-all). No Rails.cache in v1 — the cockpit must be
  # fresh; the instance memoises per request like the other dashboard services.
  class CrossOrgActionSummary
    TOP_N = 5

    OrgActionSlice = Struct.new(
      :organisation, :tickets, :ticket_count, :notifications, :notification_count, :unread_count,
      :error, keyword_init: true
    ) do
      # Assigned tickets + unread notifications are the "things that need you".
      def actionable_count
        ticket_count + notification_count
      end

      def any?
        actionable_count.positive?
      end
    end

    # importance: one of User::PreferenceStore::COCKPIT_IMPORTANCE_LEVELS. Defensively normalised to
    # the canonical default — the service is a public seam, not only fed by the (already validating)
    # controller + store.
    def initialize(user:, importance: User::PreferenceStore::COCKPIT_DEFAULT_IMPORTANCE)
      @user = user
      @importance = normalize_importance(importance)
    end

    # Slices worth showing: orgs with ≥1 actionable item, plus any org that errored (so the
    # view can show a quiet "couldn't load" note instead of silently dropping it). Ordered by
    # the user's active-org order.
    def slices
      @slices ||= all_slices.select { |slice| slice.any? || slice.error }
    end

    # Σ(assigned tickets + mentions) across all orgs — the honest "X Dinge brauchen dich".
    # Error slices contribute 0.
    def total
      @total ||= slices.sum(&:actionable_count)
    end

    # Permission-correct unread-in-app count per org, for EVERY active org (the org tiles need
    # it, not just the actionable ones). Computed from the same per-org pass, so no extra
    # queries beyond the iteration. Replaces the old without_tenant grouped count, which
    # ignored project-access (counted notifications for projects the user can no longer see).
    def unread_counts
      @unread_counts ||= all_slices.to_h { |slice| [slice.organisation.id, slice.unread_count] }
    end

    # Every org's slice (actionable or not, including error slices) keyed by org id. Pure projection
    # of the memoised all_slices — NO extra queries. The rows layout needs a slice for EVERY active
    # org (even "all quiet" ones), unlike #slices which only returns orgs with something actionable.
    def slices_by_org
      @slices_by_org ||= all_slices.index_by { |slice| slice.organisation.id }
    end

    private

    attr_reader :user, :importance

    # Clamp the importance to a known level. The controller + store already validate, but the service
    # is a public seam (callable directly in jobs/specs), so an unknown value falls back to the
    # default rather than silently showing nothing.
    def normalize_importance(value)
      levels = User::PreferenceStore::COCKPIT_IMPORTANCE_LEVELS
      levels.include?(value) ? value : User::PreferenceStore::COCKPIT_DEFAULT_IMPORTANCE
    end

    def all_slices
      # One pass over the user's active orgs. The repeated per-org SQL is the intentional
      # per-tenant loop (bounded by org count), NOT a per-record N+1 — `aggregate_org_slice`
      # is allow-listed in spec/support/prosopite.rb for exactly this reason (same rationale
      # as Wiki::NoteBackfill#backfill_tenant).
      @all_slices ||= user.active_organisations.map { |org| aggregate_org_slice(org) }
    end

    def aggregate_org_slice(organisation)
      ActsAsTenant.with_tenant(organisation) do
        # The ticket query's project set. The unread relation asks Notification.readable itself
        # (per area); its "any area" set is the same memoised relation, so it costs no second
        # resolution.
        project_ids = accessible_project_ids(organisation)

        # Build the unread relation ONCE (P2): the count, the top-N list, and the tile unread_count
        # all derive from it (notification_count == unread_count by construction). Eager-load the
        # actor/notifiable/project the view's title + deep-link touch — the cockpit renders WITHOUT a
        # tenant, so a lazy association load there would raise NoTenantSet (A9).
        unread_relation = Notification.inbox_unread(user, organisation)
        unread_total = unread_relation.count

        tickets_relation = tickets_for_importance(project_ids)

        OrgActionSlice.new(
          organisation: organisation,
          ticket_count: tickets_relation.count,
          tickets: tickets_relation.includes(:project).by_priority.limit(TOP_N).to_a,
          notification_count: unread_total,
          notifications: unread_relation.recent.includes(:actor, :notifiable, :project).limit(TOP_N).to_a,
          unread_count: unread_total,
          error: false
        )
      end
    rescue StandardError => e
      # One org's failure must never take down the whole cockpit. Skip it with an error flag;
      # the view renders a quiet "Konnte <Org> nicht laden" note.
      Rails.logger.error("CrossOrgActionSummary failed for org #{organisation.id}: #{e.class}: #{e.message}")
      OrgActionSlice.new(
        organisation: organisation, tickets: [], ticket_count: 0,
        notifications: [], notification_count: 0, unread_count: 0, error: true
      )
    end

    # Tickets to show for the current importance level. :notifications -> none; :all -> every
    # assigned active ticket; :important -> narrowed to overdue OR high priority. Uses due_in_past
    # (NOT the overdue scope) on purpose: the base set is already active, and due_in_past is a pure
    # WHERE so it composes with .or in ONE query, whereas overdue would re-pluck project_ids per org.
    def tickets_for_importance(project_ids)
      return Ticket.none if importance == 'notifications'

      base = assigned_open_tickets(project_ids)
      return base if importance == 'all'

      base.due_in_past.or(base.high_priority)
    end

    # Active projects in this org the user may read, resolved once per org and reused for the
    # unread count, the ticket query and the closed/backlog status-value lookup. Asked through
    # Notification.source_projects_for because the tile counts by the inbox rule; for tickets it
    # is the same set (Overview::MyOpenTicketsComponent#project_ids).
    def accessible_project_ids(organisation)
      Notification.source_projects_for(user, organisation).pluck(:id)
    end

    # Assigned, still-active tickets the user may see. Empty project set -> Ticket.none so
    # .count and .limit stay valid (no all-org leak).
    def assigned_open_tickets(project_ids)
      return Ticket.none if project_ids.empty?

      TicketPolicy::Scope.new(user, Ticket.where(project_id: project_ids))
                         .resolve
                         .assigned_to(user)
                         .excluding_status_values(inactive_status_values(project_ids))
    end

    # "Open" = active work: not closed AND not backlog. Same definition as the overview widget.
    def inactive_status_values(project_ids)
      TicketAttributeDefinition.closed_status_values_for(project_ids) |
        TicketAttributeDefinition.backlog_status_values_for(project_ids)
    end
  end
end
