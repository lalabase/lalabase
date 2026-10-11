# frozen_string_literal: true

module Overview
  # Org-wide portfolio aggregates for the overview's portfolio widgets (org_stats_cards +
  # billing_overview). Deliberately SEPARATE from Dashboard::DailyBriefing: the briefing is
  # today-focus / me-centric (this week's hours, activity since the daily cutoff), whereas these are
  # org totals with no time window. Keeping them apart stops the two from blurring.
  #
  # Everything is PERMISSION-SCOPED to the viewer: counts/sums run over the projects the user can
  # access (ProjectPolicy::Scope on the org's ACTIVE projects), plus the per-area policy scopes for
  # tickets / time sessions. A member who can see one of five projects gets one project's numbers,
  # never a leak of the rest.
  #
  # Every aggregate is memoised so a request that renders BOTH portfolio widgets shares one set of
  # queries (the same reason DailyBriefing is built once and injected).
  class PortfolioStats
    def initialize(organisation:, user:)
      @organisation = organisation
      @user = user
    end

    # org_stats_cards: number of ACTIVE projects the viewer can access.
    def active_projects_count
      permitted_projects.size
    end

    # org_stats_cards: open tickets across all the viewer's projects. "Open" = active work — not in a
    # status a project's System Functions mark as closed/completed OR parked in a backlog. Mirrors the
    # project dashboard's open-ticket definition (StatsCardsComponent#inactive_status_values) so "open"
    # counts the same on both surfaces, via the System-Function-driven status values (not a hardcoded
    # "done").
    def open_tickets_count
      return 0 if project_ids.empty?

      TicketPolicy::Scope.new(user, Ticket.where(project_id: project_ids))
                         .resolve
                         .excluding_status_values(inactive_status_values)
                         .count
    end

    # org_stats_cards: tickets past their due date and not yet closed/completed, across the viewer's
    # projects. Uses Ticket.overdue (date < today AND not in a closed/completed status per the
    # project's System Functions) — the same overdue definition as the badge/chip on every ticket surface.
    def overdue_tickets_count
      return 0 if project_ids.empty?

      TicketPolicy::Scope.new(user, Ticket.where(project_id: project_ids))
                         .resolve
                         .overdue
                         .count
    end

    # org_stats_cards: all not-yet-billed hours (loose + already grouped for billing).
    def unbilled_hours
      to_hours(without_billing_minutes + in_billing_minutes)
    end

    # --- billing_overview pipeline (hours; there is no monetary rate in the data model) ---
    # Unbilled and NOT yet grouped into a billing group (the raw backlog).
    def without_billing_hours
      to_hours(without_billing_minutes)
    end

    # Unbilled but already grouped into a billing group (in the invoicing pipeline, not yet marked billed).
    def in_billing_hours
      to_hours(in_billing_minutes)
    end

    # Marked as billed.
    def billed_hours
      to_hours(billed_minutes)
    end

    private

    attr_reader :organisation, :user

    def to_hours(minutes)
      (minutes / 60.0).round(1)
    end

    def permitted_projects
      @permitted_projects ||= ProjectPolicy::Scope.new(user, organisation.projects.active).resolve.to_a
    end

    def project_ids
      @project_ids ||= permitted_projects.map(&:id)
    end

    # "Not active work" = closed (is_closed/is_completed) + backlog (is_backlog), per the status
    # attribute's System Functions. Same union the project dashboard uses
    # (StatsCardsComponent#inactive_status_values). #126 generalised excluding_closed ->
    # excluding_status_values and added the backlog dimension; this is the overview's counterpart.
    def inactive_status_values
      @inactive_status_values ||= TicketAttributeDefinition.closed_status_values_for(project_ids) |
                                  TicketAttributeDefinition.backlog_status_values_for(project_ids)
    end

    # Time sessions the viewer may see across their projects (TimeSessionPolicy handles the
    # time-tracking-specific visibility), reused by every hours figure below.
    def permitted_time_sessions
      @permitted_time_sessions ||= if project_ids.empty?
                                     TimeSession.none
                                   else
                                     TimeSessionPolicy::Scope.new(
                                       user, TimeSession.where(project_id: project_ids, organisation: organisation)
                                     ).resolve
                                   end
    end

    def without_billing_minutes
      @without_billing_minutes ||= permitted_time_sessions.where(billed: false, time_session_group_id: nil).sum(:duration)
    end

    def in_billing_minutes
      @in_billing_minutes ||= permitted_time_sessions.where(billed: false).where.not(time_session_group_id: nil).sum(:duration)
    end

    def billed_minutes
      @billed_minutes ||= permitted_time_sessions.where(billed: true).sum(:duration)
    end
  end
end
