# frozen_string_literal: true

# Today-focus dashboard: "What is new since yesterday 6 a.m.?" for the current
# organisation. Replaces the old projects index as the organisation root.
class Organisations::BriefingsController < Organisations::BaseController
  # No policy needed — we only show data the user is already authorised for
  # (every aggregation runs through the relevant Policy::Scope).
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def show
    # D1: the old "no time access -> redirect to inbox" guard is gone. The overview is configurable
    # and the widgets gate themselves (a viewer without time access simply doesn't get the hours
    # widgets); a viewer who ends up with zero visible widgets sees the empty state (see the view),
    # not a blank page.

    # One shared DailyBriefing per request, injected into every converted widget via the overview
    # base_params (D6) so they reuse its memoised aggregates instead of each re-querying.
    @briefing = Dashboard::DailyBriefing.new(
      user: current_user,
      organisation: @current_organisation
    )

    # Resolve the overview layout cascade (personal config -> org default -> system default) through
    # the shared engine; `owned` drives the permission-aware placeholder behaviour at render time.
    resolution = Dashboards::LayoutEngine.resolve_cascade(
      config_class: OverviewConfiguration,
      scope: { organisation: @current_organisation },
      user: current_user,
      system_default: Overview::WidgetRegistry::SYSTEM_DEFAULT_LAYOUT
    )
    @overview_layout = resolution.layout
    @overview_layout_owned = resolution.owned

    # Kettenglied 0 (doc/onboarding_plan.md, D4): banner ABOVE the widget grid
    # pointing at the seeded tutorial project. Deliberately NOT a widget — no
    # registry entry, no layout mutation.
    @onboarding_banner_project = onboarding_banner_project
  end

  private

  # Visible while the org's onboarding project still has open tutorial tickets
  # and the viewer hasn't dismissed it (per user + org). "Open" = not in a
  # CLOSED status — deliberately NOT the my_open_tickets set, which also
  # excludes backlog: a tutorial ticket parked in the backlog is postponed,
  # not done, so the banner keeps pointing at it. One indexed lookup + one
  # exists? — cheap enough to run on every overview render.
  def onboarding_banner_project
    return nil if current_user.preference_store.onboarding_banner_dismissed?(@current_organisation)

    project = @current_organisation.projects.find_by(system_kind: Actors::SeedOnboarding::PROJECT_SYSTEM_KIND)
    return nil unless project

    closed_values = TicketAttributeDefinition.closed_status_values_for([project.id])
    project.tickets.excluding_status_values(closed_values).exists? ? project : nil
  end
end
